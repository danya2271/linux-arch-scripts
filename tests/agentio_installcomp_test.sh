#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d --tmpdir agentio-installcomp.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

export AGENTIO_HOME="$TEST_DIR/agentio"
export XDG_CONFIG_HOME="$TEST_DIR/config"
export TEST_LOG="$TEST_DIR/commands.log"
export PATH="$TEST_DIR/bin:/usr/bin:/bin"

mkdir -p "$TEST_DIR/bin"

make_stub() {
    local name="$1"
    shift
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$@"
    } > "$TEST_DIR/bin/$name"
    chmod +x "$TEST_DIR/bin/$name"
}

# These expressions expand when their generated stub runs, not here.
# shellcheck disable=SC2016
make_stub sudo \
    'printf '\''sudo <%s>\n'\'' "$*" >> "$TEST_LOG"'

# shellcheck disable=SC2016
make_stub git \
    'printf '\''git <%s>\n'\'' "$*" >> "$TEST_LOG"' \
    'if [ "${1:-}" = clone ]; then' \
    '    destination="${!#}"' \
    '    mkdir -p "$destination/.git"' \
    'fi'

# shellcheck disable=SC2016
make_stub cmake \
    'printf '\''cmake-arg <%s>\n'\'' "$@" >> "$TEST_LOG"'

make_stub nvcc 'exit 0'
make_stub nproc 'printf '\''2\n'\'''

: > "$TEST_LOG"
"$ROOT_DIR/agentio.sh" installcomp > "$TEST_DIR/installcomp.out"

grep -Fqx 'cmake-arg <-DGGML_CUDA=ON>' "$TEST_LOG"
grep -Fqx 'cmake-arg <-DCMAKE_CUDA_FLAGS=-fmad=false -DNO_DP4A>' "$TEST_LOG"
grep -Fq 'CMP compatibility profile enabled (NO_DP4A, -fmad=false).' "$TEST_DIR/installcomp.out"
grep -Fq 'CMP-optimized setup complete.' "$TEST_DIR/installcomp.out"

echo 'AgentIO installcomp test passed.'
