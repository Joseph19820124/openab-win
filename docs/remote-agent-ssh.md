# Remote agent over SSH

Run the agent CLI (e.g. `gemini`, `kiro-cli`, `codex-acp`,
`claude-agent-acp`) on a remote host — typically an EC2 instance — while
`openab` itself stays on your laptop (Mac or Windows). The SSH tunnel
transparently forwards the agent's stdio JSON-RPC stream, so **no code
changes are required**: `openab` still thinks it is talking to a local
child process.

This document walks through the canonical setup: **Mac for development,
Windows for production, both pointing at a shared Tokyo EC2 running
`gemini --acp`.**

```
┌─ Your laptop ────────┐          ┌─ EC2 (ap-northeast-1) ──────┐
│  openab              │          │  sshd                       │
│   │                  │  SSH     │   └─ gemini --acp           │
│   └─ spawns "ssh" ───┼──tunnel──┼───────► generativelanguage. │
└──────────────────────┘          │         googleapis.com      │
         ▲                        └─────────────────────────────┘
         │ Discord / Slack Gateway
```

## When this makes sense

- You develop on macOS but deploy on Windows and want **one agent
  environment** (API keys, MCP servers, working directories, auth
  tokens) shared by both clients.
- Your laptop is in a network where direct calls to the model provider
  are slow or restricted, but the EC2 region has a clean route.
- You want to keep the Windows host footprint tiny — only `openab.exe`
  and the built-in `ssh.exe` (Windows 10+).

## Latency expectations

Measured from a Shanghai-area Mac to `ec2.ap-northeast-1.amazonaws.com`:

| Hop | RTT |
|---|---|
| Laptop → Tokyo EC2 | ~100 ms (85 – 144 ms) |
| Tokyo EC2 → Gemini API | ~30 – 80 ms (Google edge in Tokyo) |

This adds roughly **130 – 200 ms to time-to-first-token** vs. a local
agent. Because `openab` debounces Discord message edits at 1.5 s, the
extra latency is rarely perceptible during streaming output.

> Gemini API has Google edge presence in Tokyo, so the EC2 → model hop is
> **faster** than the OpenAI equivalent (which terminates in the US).
> This is a mild reason to prefer Gemini for this topology.

## 1. Provision the EC2 instance

Any region with a good route to your laptop works; Tokyo
(`ap-northeast-1`) is a good default for clients in East Asia.

Recommended: **Amazon Linux 2023** on `t3.small` (2 vCPU / 2 GiB) — plenty
for a handful of concurrent Discord threads.

```bash
# ssh into the box once
ssh ec2-user@<your-ec2-host>

# Node.js 20+ (gemini-cli is an npm package; requires Node ≥20)
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo dnf install -y nodejs        # or: sudo apt-get install -y nodejs

# Install Google's official Gemini CLI
sudo npm install -g @google/gemini-cli

# Verify
gemini --version                  # should print e.g. 0.x.y
gemini --help | grep -- --acp     # confirm the ACP flag exists
```

### Authenticate Gemini

Pick **one** of:

**(a) API key (recommended for SSH/remote setups)** — simplest, no
interactive flow, survives reboots:

```bash
# Get a key from https://aistudio.google.com/apikey
echo 'export GEMINI_API_KEY=AIza...' >> ~/.bashrc
source ~/.bashrc
```

**(b) Google OAuth (interactive device flow)** — useful if you prefer
your Google account's usage over pay-as-you-go API keys:

```bash
gemini                            # run once, follow the device auth URL
# Tokens persist in ~/.gemini/ — subsequent `gemini --acp` invocations
# pick them up automatically.
```

Sanity check (no `--acp`, just raw chat):

```bash
gemini -p "say hi"
```

## 2. Configure SSH on the laptop

On the client (Mac or Windows), add an entry to your SSH config so
`openab` can just say `ssh tokyo-agent` without repeating flags.

### macOS / Linux: `~/.ssh/config`

```ssh-config
Host tokyo-agent
    HostName ec2-xx-xx-xx-xx.ap-northeast-1.compute.amazonaws.com
    User ec2-user
    IdentityFile ~/.ssh/your-ec2-key.pem
    # Keep the tunnel alive across NAT idle timeouts
    ServerAliveInterval 30
    ServerAliveCountMax 3
    # Reuse a single TCP connection for every session — avoids repeating
    # the ~300 ms SSH handshake for each new Discord thread.
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

Pre-establish the control master once:

```bash
ssh -Nf tokyo-agent     # opens the master in the background
```

### Windows: `%USERPROFILE%\.ssh\config`

Windows 10/11 ship an OpenSSH client at `C:\Windows\System32\OpenSSH\ssh.exe`.
Same config format as above; just drop the `ControlMaster`/`ControlPath`
block — OpenSSH for Windows does not support connection multiplexing.
SSH handshake will then happen once per spawned agent (~300 ms, amortised
over the 24-hour session TTL), which is still negligible.

```ssh-config
Host tokyo-agent
    HostName ec2-xx-xx-xx-xx.ap-northeast-1.compute.amazonaws.com
    User ec2-user
    IdentityFile C:\Users\you\.ssh\your-ec2-key.pem
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

Verify: `ssh tokyo-agent echo hi` should print `hi` with no password
prompt. Then confirm gemini is reachable through the tunnel:

```bash
ssh tokyo-agent 'gemini --help | head -5'
```

## 3. Point openab at SSH

Edit `config.toml`:

```toml
[agent]
# Instead of running a local binary, spawn ssh and let it invoke the
# agent on the remote host. Use `-T` (NOT `-tt`): ACP is a JSON-RPC
# protocol over raw stdio, and a PTY would put stdin in canonical mode
# with echo + line buffering, corrupting the byte stream and hanging the
# initialize handshake.
command = "ssh"
args = [
    "-T",
    "tokyo-agent",
    # The remote command — `gemini --acp` starts ACP mode.
    # Ensure GEMINI_API_KEY is set in ~/.bashrc on the remote so a
    # login shell picks it up.
    "gemini",
    "--acp",
]
# working_dir is the *openab* working dir, not the remote agent's.
working_dir = "."
# env here is passed to ssh, not to gemini. Put GEMINI_API_KEY in the
# remote ~/.bashrc instead; passing it across SSH requires SendEnv /
# AcceptEnv on both sides and is fragile.
env = {}
```

Restart `openab`; it will spawn `ssh -T tokyo-agent gemini --acp` as
its child process, and the existing stdio JSON-RPC code talks to
`gemini` unchanged.

## 4. Verify end-to-end

1. `@mention` the bot in an allowed Discord channel.
2. Watch for the 👀 → 🤔 → 👨‍💻 reaction progression (configurable in
   `[reactions.emojis]`).
3. On the EC2 host: `ps -ef | grep '[g]emini --acp'` should show one
   process per active Discord thread, parented to `sshd`.

## Known issue: stray stdout logs in ACP mode

Gemini CLI has an open bug
([#22647](https://github.com/google-gemini/gemini-cli/issues/22647))
where it occasionally writes plain-text diagnostics (e.g. `Loaded
cached credentials.`) to **stdout** instead of stderr. That stream is
what `openab` parses as JSON-RPC, so a stray line can make `openab` log
`failed to parse message` warnings and, in the worst case, drop the
session.

Mitigations until the upstream fix lands:

- **Use an API key**, not OAuth — OAuth mode is the main source of
  these credential log lines.
- If you see the warnings, update to the latest `@google/gemini-cli` on
  the EC2 host: `sudo npm install -g @google/gemini-cli@latest`.

## Operational notes

- **Connection death:** if the SSH tunnel dies mid-session (EC2 reboot,
  network partition), the child process exits and `openab` drops that
  session. The user sees a 😱 reaction and can re-@mention to spawn a
  new tunnel. The session pool does not auto-reconnect a broken tunnel.
- **Session pool footprint:** each Discord thread keeps one SSH tunnel
  + one remote `gemini --acp` process alive for
  `pool.session_ttl_hours`. With the default 24 h TTL, 10 active threads
  = 10 sshd children and 10 gemini processes on the EC2 host. Each
  `gemini` process consumes 150 – 300 MiB RSS — size the instance
  accordingly (a `t3.small` with 2 GiB handles ~5 concurrent sessions
  comfortably).
- **Logs:** `gemini --acp` writes to stderr on the remote. To surface
  those in `openab` logs, change the spawn in
  `src/acp/connection.rs` to pipe stderr (currently `Stdio::null`).
  Not enabled by default to avoid noise.
- **Security:** use a dedicated EC2 user with no sudo, restrict the
  security group to your laptop's egress IP (or use SSM Session Manager
  to skip exposing port 22 entirely), and rotate the SSH key
  periodically. The Gemini API key lives only on the EC2 box.

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `gemini: command not found` | npm global bin not on remote non-login `PATH`. Fix by either using the absolute path (`args = ["-T", "tokyo-agent", "/usr/bin/gemini", "--acp"]`) or exporting `PATH` in the remote `~/.bashrc` so it applies to non-interactive SSH sessions. |
| `initialize` hangs forever, no JSON response over SSH | You used `-tt` instead of `-T`. `-tt` allocates a PTY, which puts stdin in canonical mode and breaks the JSON-RPC stream. Use `-T`. |
| Immediate hangup after `session/new` | Missing `GEMINI_API_KEY` on remote. `ssh tokyo-agent 'env \| grep GEMINI'` should show the key. |
| `failed to parse message` spam in openab logs | Known gemini-cli stdout pollution — see "Known issue" above. Switch to API key auth and/or upgrade the CLI. |
| Session crashes right after spawn | Often a Node version mismatch — gemini-cli needs Node ≥20. `ssh tokyo-agent node --version`. |
| 500 ms+ added to every message | ControlMaster not reused. After the first `ssh` run, `ls ~/.ssh/cm-*` should show a socket; if empty, OpenSSH client is too old (<7.4) or the `ControlPath` directory is not writable. |
| 429 rate-limit errors | The free Gemini tier is generous but bursty — either throttle `pool.max_sessions` in `config.toml` or move to a billed Google Cloud project. |
| Discord bot stays offline, logs show `Err starting shard 0: ... InvalidCertificate(UnknownIssuer)` | You are behind a corporate TLS-intercepting gateway (e.g. Zscaler). The interceptor swaps Discord's cert for one signed by a private enterprise CA that is installed in the OS keychain but NOT in rustls's bundled `webpki-roots`. **Fix already applied** to `Cargo.toml`: all three TLS consumers (`serenity`, `reqwest`, `tokio-tungstenite`) are built with `native-tls` / `native_tls_backend`, which reads the OS trust store (macOS keychain, Windows cert store, Linux `/etc/ssl/certs`). If you ever switch back to `rustls_backend` you will hit this again on corp networks. |
