#!/usr/bin/env bash
# Launch openab-win on this Mac.
#
# Token and all other secrets live in config.toml (git-ignored). This
# script is just a thin release/debug switcher so you don't have to
# remember the full path.
#
# Usage:
#   ./run.sh           # release build (default, fast startup, ~30 MB binary)
#   ./run.sh debug     # cargo run (for dev iteration; slow startup, fast rebuild)
set -eu

cd "$(dirname "$0")"
CONFIG="$(pwd)/config.toml"

if [ ! -f "$CONFIG" ]; then
    echo "error: $CONFIG not found" >&2
    exit 1
fi

MODE="${1:-release}"
case "$MODE" in
    debug|dev)
        exec cargo run -- run "$CONFIG"
        ;;
    release|"")
        BIN="target/release/openab"
        if [ ! -x "$BIN" ]; then
            echo "release binary missing — building (one-time, ~1-2 min) ..." >&2
            cargo build --release
        fi
        exec "$BIN" run "$CONFIG"
        ;;
    *)
        echo "unknown mode '$MODE' — use 'release' (default) or 'debug'" >&2
        exit 1
        ;;
esac
