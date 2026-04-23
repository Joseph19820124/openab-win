# Remote agent over SSH

Run the agent CLI (e.g. `codex-acp`, `kiro-cli`, `claude-agent-acp`) on a
remote host — typically an EC2 instance — while `openab` itself stays on
your laptop (Mac or Windows). The SSH tunnel transparently forwards the
agent's stdio JSON-RPC stream, so **no code changes are required**: `openab`
still thinks it is talking to a local child process.

```
┌─ Your laptop ────────┐          ┌─ EC2 (e.g. ap-northeast-1) ─┐
│  openab              │          │  sshd                       │
│   │                  │  SSH     │   └─ codex-acp (stdin/out)  │
│   └─ spawns "ssh" ───┼──tunnel──┼───────► OpenAI API          │
└──────────────────────┘          └─────────────────────────────┘
         ▲
         │ Discord / Slack Gateway
```

## When this makes sense

- You develop on macOS but deploy on Windows and want **one agent
  environment** (auth tokens, MCP servers, working directories) shared by
  both clients.
- Your laptop is in a network where direct calls to the model provider
  (e.g. `api.openai.com`) are slow or restricted, but the EC2 region has
  a clean route.
- You want to keep the Windows host footprint tiny — only `openab.exe`
  and the built-in `ssh.exe` (Windows 10+).

## Latency expectations

Measured from a Shanghai-area Mac to `ec2.ap-northeast-1.amazonaws.com`:

| Hop | RTT |
|---|---|
| Laptop → Tokyo EC2 | ~100 ms (85 – 144 ms) |
| Tokyo EC2 → OpenAI API | ~100 – 150 ms |

This adds roughly **150 – 250 ms to time-to-first-token** vs. a local
agent. Because `openab` debounces Discord message edits at 1.5 s, the
extra latency is rarely perceptible during streaming output.

## 1. Provision the EC2 instance

Any region with a good route to your laptop works; Tokyo
(`ap-northeast-1`) is a good default for clients in East Asia.

Minimum recipe (Amazon Linux 2023 or Ubuntu 24.04):

```bash
# ssh into the box once
ssh ec2-user@<your-ec2-host>

# Node.js 20+ (codex-acp is an npm package)
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo dnf install -y nodejs          # or: sudo apt-get install -y nodejs

# Install the Zed codex adapter and the underlying OpenAI Codex CLI
sudo npm install -g @zed-industries/codex-acp @openai/codex

# Authenticate — pick one:
#   (a) API key (simplest; persists across reboots via ~/.profile)
echo 'export OPENAI_API_KEY=sk-...' >> ~/.bashrc

#   (b) ChatGPT subscription (device flow, does NOT work for remote projects
#       — only (a) is recommended for this SSH setup)
# codex login --device-auth

# Sanity check
codex-acp --help        # should print ACP adapter usage
```

> **Note:** The ChatGPT-subscription login path is explicitly unsupported
> for "remote projects" by the upstream adapter. Use `OPENAI_API_KEY` for
> this SSH topology.

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

Verify: `ssh tokyo-agent echo hi` should print `hi` with no password prompt.

## 3. Point openab at SSH

Edit `config.toml`:

```toml
[agent]
# Instead of running a local binary, spawn ssh and let it invoke the
# agent on the remote host. -tt forces a PTY, which many ACP adapters
# expect for well-behaved stdin buffering.
command = "ssh"
args = [
    "-tt",
    "tokyo-agent",
    # The remote command: ensure OPENAI_API_KEY is set in ~/.bashrc or
    # similar so login shells pick it up. `codex-acp` takes no flags.
    "codex-acp",
]
# working_dir is the *openab* working dir, not the remote agent's.
working_dir = "."
# env here is passed to ssh, not to codex-acp. Put OPENAI_API_KEY in the
# remote ~/.bashrc instead; passing it across SSH requires SendEnv /
# AcceptEnv on both sides and is fragile.
env = {}
```

That's it. Restart `openab`; it will spawn `ssh -tt tokyo-agent codex-acp`
as its child process, and the existing stdio JSON-RPC code speaks to
`codex-acp` unchanged.

## 4. Verify end-to-end

1. `@mention` the bot in an allowed Discord channel.
2. Watch for the 👀 → 🤔 → 👨‍💻 reaction progression (configurable in
   `[reactions.emojis]`).
3. On the EC2 host: `ps -ef | grep codex-acp` should show one process
   per active Discord thread, parented to `sshd`.

## Operational notes

- **Connection death:** if the SSH tunnel dies mid-session (EC2 reboot,
  network partition), the child process exits and `openab` drops that
  session. The user sees a 😱 reaction and can re-@mention to spawn a new
  tunnel. The session pool will not automatically reconnect a broken
  tunnel.
- **Session pool footprint:** each Discord thread keeps one SSH tunnel +
  one remote `codex-acp` process alive for `pool.session_ttl_hours`.
  With the default 24 h TTL, 10 active threads = 10 sshd children and
  10 codex-acp children on the EC2 host. Raise the instance size or
  lower `pool.max_sessions` accordingly.
- **Logs:** `codex-acp` writes to stderr on the remote. To surface
  those in `openab` logs, change the spawn in `src/acp/connection.rs`
  to pipe stderr (currently `Stdio::null`). Not enabled by default to
  avoid noise.
- **Security:** use a dedicated EC2 user with no sudo, restrict the
  security group to your laptop's egress IP, and rotate the SSH key
  periodically. The OpenAI API key lives only on the EC2 box.

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `codex-acp: command not found` | npm global bin not on login-shell PATH. Either use `-tt` (forces login shell) or absolute path `/usr/bin/codex-acp`. |
| Immediate hangup after `session/new` | Missing `OPENAI_API_KEY` on remote. `ssh tokyo-agent 'env \| grep OPENAI'` should show the key. |
| 500 ms+ added to every message | ControlMaster not reused — check `ls ~/.ssh/cm-*` after a session; if empty, the socket path is wrong or your SSH is too old (<7.4). |
| Discord message says "session crashed" right after spawn | Often a node version mismatch — `codex-acp` needs Node 20+. `ssh tokyo-agent node --version`. |
