#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d --tmpdir agentio-persistence.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

export AGENTIO_HOME="$TEST_DIR/agentio"
export XDG_CONFIG_HOME="$TEST_DIR/config"
export TEST_LOG="$TEST_DIR/commands.log"
export LINGER_STATE=no

loginctl() {
    case "$1" in
        show-user) printf '%s\n' "$LINGER_STATE" ;;
        enable-linger) LINGER_STATE=yes ;;
        *) return 1 ;;
    esac
}

sudo() {
    printf 'sudo %s\n' "$*" >> "$TEST_LOG"
    "$@"
}

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
    return 0
}

sleep() { :; }

export -f loginctl sudo systemctl sleep

mkdir -p "$AGENTIO_HOME/llama.cpp/build/bin" "$AGENTIO_HOME/models"
ln -s /usr/bin/true "$AGENTIO_HOME/llama.cpp/build/bin/llama-server"
ln -s /etc/hosts "$AGENTIO_HOME/models/model.gguf"
: > "$TEST_LOG"

"$ROOT_DIR/agentio.sh" start model.gguf > "$TEST_DIR/start.out"

grep -q '^sudo loginctl enable-linger ' "$TEST_LOG"
grep -qx 'Restart=always' "$XDG_CONFIG_HOME/systemd/user/agentio.service"
if grep -q '^Restart=on-failure$' "$XDG_CONFIG_HOME/systemd/user/agentio.service"; then
    echo 'The generated unit still uses Restart=on-failure.' >&2
    exit 1
fi

export LINGER_STATE=yes
: > "$TEST_LOG"
"$ROOT_DIR/agentio.sh" start > "$TEST_DIR/restart.out"

if grep -q '^sudo ' "$TEST_LOG"; then
    echo 'AgentIO requested sudo even though lingering was already enabled.' >&2
    exit 1
fi

echo 'AgentIO persistence test passed.'
