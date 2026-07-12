#!/usr/bin/env bash

# AgentIO - persistent llama.cpp model and systemd service manager.

set -o pipefail

AGENT_DIR="${AGENTIO_HOME:-$HOME/.agentio}"
MODELS_DIR="$AGENT_DIR/models"
LLAMA_DIR="$AGENT_DIR/llama.cpp"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentio"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
LAUNCHER_FILE="$CONFIG_DIR/run-server"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_NAME="agentio.service"
SERVICE_FILE="$SYSTEMD_DIR/$SERVICE_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}$*${NC}"; }
ok() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
ensure_dirs() { mkdir -p "$MODELS_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR" || die "Could not create AgentIO directories."; }

# Settings defaults. Values are persisted as shell-escaped assignments in a
# user-only file. EXTRA_ARGS is an array so arguments containing spaces survive.
set_defaults() {
    MODEL=""
    HOST="127.0.0.1"
    PORT="8080"
    API_KEY=""
    CTX_SIZE="4096"
    GPU_LAYERS="99"
    THREADS="0"
    THREADS_BATCH="0"
    BATCH_SIZE="2048"
    UBATCH_SIZE="512"
    PARALLEL="1"
    FLASH_ATTN="auto"
    CACHE_TYPE_K="f16"
    CACHE_TYPE_V="f16"
    SPLIT_MODE="layer"
    TENSOR_SPLIT=""
    MAIN_GPU="0"
    MMAP="on"
    MLOCK="off"
    NUMA="disabled"
    CONT_BATCHING="on"
    KV_UNIFIED="off"
    SWA_FULL="off"
    OP_OFFLOAD="on"
    POLL="50"
    CPU_MASK=""
    CPU_RANGE=""
    CPU_STRICT="off"
    PRIORITY="0"
    CPU_MASK_BATCH=""
    CPU_RANGE_BATCH=""
    CPU_STRICT_BATCH="auto"
    PRIORITY_BATCH=""
    POLL_BATCH=""
    DEFRAG_THOLD=""
    PERF="off"
    KV_OFFLOAD="on"
    REPACK="on"
    HOST_BUFFER="on"
    DIRECT_IO="off"
    DEVICE=""
    CPU_MOE="off"
    N_CPU_MOE="0"
    FIT="on"
    FIT_TARGET="1024"
    FIT_CTX="4096"
    CACHE_RAM="8192"
    CACHE_IDLE_SLOTS="on"
    CACHE_PROMPT="on"
    CACHE_REUSE="0"
    THREADS_HTTP="0"
    EXTRA_ARGS=()
}

load_settings() {
    set_defaults
    if [ -f "$CONFIG_FILE" ]; then
        # The file is created mode 600 and every value is written with printf %q.
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

write_assignment() {
    local name="$1" value="$2"
    printf '%s=' "$name"
    printf '%q' "$value"
    printf '\n'
}

save_settings() {
    local tmp="$CONFIG_FILE.tmp"
    umask 077
    {
        echo '# AgentIO settings; managed by agentio settings.'
        write_assignment MODEL "$MODEL"
        write_assignment HOST "$HOST"
        write_assignment PORT "$PORT"
        write_assignment API_KEY "$API_KEY"
        write_assignment CTX_SIZE "$CTX_SIZE"
        write_assignment GPU_LAYERS "$GPU_LAYERS"
        write_assignment THREADS "$THREADS"
        write_assignment THREADS_BATCH "$THREADS_BATCH"
        write_assignment BATCH_SIZE "$BATCH_SIZE"
        write_assignment UBATCH_SIZE "$UBATCH_SIZE"
        write_assignment PARALLEL "$PARALLEL"
        write_assignment FLASH_ATTN "$FLASH_ATTN"
        write_assignment CACHE_TYPE_K "$CACHE_TYPE_K"
        write_assignment CACHE_TYPE_V "$CACHE_TYPE_V"
        write_assignment SPLIT_MODE "$SPLIT_MODE"
        write_assignment TENSOR_SPLIT "$TENSOR_SPLIT"
        write_assignment MAIN_GPU "$MAIN_GPU"
        write_assignment MMAP "$MMAP"
        write_assignment MLOCK "$MLOCK"
        write_assignment NUMA "$NUMA"
        write_assignment CONT_BATCHING "$CONT_BATCHING"
        write_assignment KV_UNIFIED "$KV_UNIFIED"
        write_assignment SWA_FULL "$SWA_FULL"
        write_assignment OP_OFFLOAD "$OP_OFFLOAD"
        write_assignment POLL "$POLL"
        write_assignment CPU_MASK "$CPU_MASK"
        write_assignment CPU_RANGE "$CPU_RANGE"
        write_assignment CPU_STRICT "$CPU_STRICT"
        write_assignment PRIORITY "$PRIORITY"
        write_assignment CPU_MASK_BATCH "$CPU_MASK_BATCH"
        write_assignment CPU_RANGE_BATCH "$CPU_RANGE_BATCH"
        write_assignment CPU_STRICT_BATCH "$CPU_STRICT_BATCH"
        write_assignment PRIORITY_BATCH "$PRIORITY_BATCH"
        write_assignment POLL_BATCH "$POLL_BATCH"
        write_assignment DEFRAG_THOLD "$DEFRAG_THOLD"
        write_assignment PERF "$PERF"
        write_assignment KV_OFFLOAD "$KV_OFFLOAD"
        write_assignment REPACK "$REPACK"
        write_assignment HOST_BUFFER "$HOST_BUFFER"
        write_assignment DIRECT_IO "$DIRECT_IO"
        write_assignment DEVICE "$DEVICE"
        write_assignment CPU_MOE "$CPU_MOE"
        write_assignment N_CPU_MOE "$N_CPU_MOE"
        write_assignment FIT "$FIT"
        write_assignment FIT_TARGET "$FIT_TARGET"
        write_assignment FIT_CTX "$FIT_CTX"
        write_assignment CACHE_RAM "$CACHE_RAM"
        write_assignment CACHE_IDLE_SLOTS "$CACHE_IDLE_SLOTS"
        write_assignment CACHE_PROMPT "$CACHE_PROMPT"
        write_assignment CACHE_REUSE "$CACHE_REUSE"
        write_assignment THREADS_HTTP "$THREADS_HTTP"
        printf 'EXTRA_ARGS=('; printf ' %q' "${EXTRA_ARGS[@]}"; echo ' )'
    } > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

detect_os() {
    OS=""
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS="$ID"
    fi
}

install_dependencies() {
    detect_os
    info "Installing dependencies for $OS..."
    case "$OS" in
        arch|manjaro) sudo pacman -S --needed git cmake make gcc curl wget cuda base-devel ;;
        ubuntu|debian|pop) sudo apt-get update && sudo apt-get install -y build-essential cmake git curl wget nvidia-cuda-toolkit ;;
        *) die "Unsupported distribution '$OS'. Install Git, CMake, a C++ compiler, curl/wget, and optionally CUDA manually." ;;
    esac
}

build_llamacpp() {
    detect_os
    info "Pulling the latest llama.cpp from GitHub..."
    if [ ! -d "$LLAMA_DIR/.git" ]; then
        git clone --depth=1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR" || exit 1
    else
        git -C "$LLAMA_DIR" pull --ff-only || exit 1
    fi

    local cmake_flags=()
    if [ -x /opt/cuda/bin/nvcc ] || command -v nvcc >/dev/null 2>&1; then
        ok "NVIDIA CUDA detected; enabling GPU acceleration."
        cmake_flags+=(-DGGML_CUDA=ON)
        [ -d /opt/cuda/bin ] && export PATH="/opt/cuda/bin:$PATH"
    else
        warn "CUDA was not detected; building for CPU only."
    fi
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" "${cmake_flags[@]}" || exit 1
    cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)" || exit 1
    ok "llama.cpp built successfully."
}

setup() {
    if [ "$0" != /usr/local/bin/agentio ]; then
        info "Installing AgentIO as /usr/local/bin/agentio..."
        sudo install -m 0755 "$0" /usr/local/bin/agentio || exit 1
    fi
    install_dependencies
    build_llamacpp
    load_settings
    save_settings
    ok "Setup complete. Configure it with: agentio settings"
}

get_server_binary() {
    local path
    for path in \
        "$LLAMA_DIR/build/bin/llama-server" \
        "$LLAMA_DIR/build/llama-server" \
        "$LLAMA_DIR/llama-server"; do
        [ -x "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

find_models() {
    find "$MODELS_DIR" -type f -iname '*.gguf' -not -name '*.part' -printf '%P\0' 2>/dev/null | sort -z -f
}

resolve_model() {
    local requested="$1" candidate match="" count=0
    [ -n "$requested" ] || return 1
    requested="${requested#./}"
    [ -f "$MODELS_DIR/$requested" ] && { printf '%s\n' "$MODELS_DIR/$requested"; return 0; }
    while IFS= read -r -d '' candidate; do
        if [ "${candidate##*/}" = "$requested" ]; then
            match="$MODELS_DIR/$candidate"
            count=$((count + 1))
        fi
    done < <(find_models)
    [ "$count" -eq 1 ] && { printf '%s\n' "$match"; return 0; }
    [ "$count" -gt 1 ] && die "More than one model is named '$requested'; use its relative path from $MODELS_DIR."
    return 1
}

add_bool_flag() {
    local value="$1" on_flag="$2" off_flag="${3:-}"
    case "$value" in
        on) SERVER_ARGS+=("$on_flag") ;;
        off) [ -n "$off_flag" ] && SERVER_ARGS+=("$off_flag") ;;
    esac
}

build_server_args() {
    local model_path="$1"
    SERVER_ARGS=(
        -m "$model_path" --host "$HOST" --port "$PORT"
        -c "$CTX_SIZE" -ngl "$GPU_LAYERS"
        --batch-size "$BATCH_SIZE" --ubatch-size "$UBATCH_SIZE"
        --parallel "$PARALLEL" --cache-type-k "$CACHE_TYPE_K"
        --cache-type-v "$CACHE_TYPE_V" --split-mode "$SPLIT_MODE"
        --main-gpu "$MAIN_GPU" --poll "$POLL" --prio "$PRIORITY"
    )
    [ "$THREADS" != 0 ] && SERVER_ARGS+=(--threads "$THREADS")
    [ "$THREADS_BATCH" != 0 ] && SERVER_ARGS+=(--threads-batch "$THREADS_BATCH")
    [ -n "$TENSOR_SPLIT" ] && SERVER_ARGS+=(--tensor-split "$TENSOR_SPLIT")
    [ -n "$CPU_MASK" ] && SERVER_ARGS+=(--cpu-mask "$CPU_MASK")
    [ -n "$CPU_RANGE" ] && SERVER_ARGS+=(--cpu-range "$CPU_RANGE")
    [ -n "$CPU_MASK_BATCH" ] && SERVER_ARGS+=(--cpu-mask-batch "$CPU_MASK_BATCH")
    [ -n "$CPU_RANGE_BATCH" ] && SERVER_ARGS+=(--cpu-range-batch "$CPU_RANGE_BATCH")
    [ "$CPU_STRICT_BATCH" != auto ] && SERVER_ARGS+=(--cpu-strict-batch "$([ "$CPU_STRICT_BATCH" = on ] && echo 1 || echo 0)")
    [ -n "$PRIORITY_BATCH" ] && SERVER_ARGS+=(--prio-batch "$PRIORITY_BATCH")
    [ -n "$POLL_BATCH" ] && SERVER_ARGS+=(--poll-batch "$POLL_BATCH")
    [ -n "$DEFRAG_THOLD" ] && SERVER_ARGS+=(--defrag-thold "$DEFRAG_THOLD")
    [ -n "$API_KEY" ] && SERVER_ARGS+=(--api-key "$API_KEY")
    [ -n "$DEVICE" ] && SERVER_ARGS+=(--device "$DEVICE")
    [ "$N_CPU_MOE" != 0 ] && SERVER_ARGS+=(--n-cpu-moe "$N_CPU_MOE")
    [ "$THREADS_HTTP" != 0 ] && SERVER_ARGS+=(--threads-http "$THREADS_HTTP")
    SERVER_ARGS+=(--fit "$FIT" --fit-target "$FIT_TARGET" --fit-ctx "$FIT_CTX")
    SERVER_ARGS+=(--cache-ram "$CACHE_RAM" --cache-reuse "$CACHE_REUSE")
    [ "$FLASH_ATTN" != auto ] && SERVER_ARGS+=(--flash-attn "$FLASH_ATTN")
    add_bool_flag "$MMAP" --mmap --no-mmap
    add_bool_flag "$MLOCK" --mlock
    [ "$NUMA" != disabled ] && SERVER_ARGS+=(--numa "$NUMA")
    add_bool_flag "$CONT_BATCHING" --cont-batching --no-cont-batching
    add_bool_flag "$KV_UNIFIED" --kv-unified --no-kv-unified
    add_bool_flag "$SWA_FULL" --swa-full
    add_bool_flag "$OP_OFFLOAD" --op-offload --no-op-offload
    SERVER_ARGS+=(--cpu-strict "$([ "$CPU_STRICT" = on ] && echo 1 || echo 0)")
    add_bool_flag "$PERF" --perf --no-perf
    add_bool_flag "$KV_OFFLOAD" --kv-offload --no-kv-offload
    add_bool_flag "$REPACK" --repack --no-repack
    [ "$HOST_BUFFER" = off ] && SERVER_ARGS+=(--no-host)
    add_bool_flag "$DIRECT_IO" --direct-io --no-direct-io
    add_bool_flag "$CPU_MOE" --cpu-moe
    add_bool_flag "$CACHE_IDLE_SLOTS" --cache-idle-slots --no-cache-idle-slots
    add_bool_flag "$CACHE_PROMPT" --cache-prompt --no-cache-prompt
    SERVER_ARGS+=("${EXTRA_ARGS[@]}")
}

write_service_files() {
    local server_bin model_path
    server_bin="$(get_server_binary)" || die "llama-server was not found. Run 'agentio install'."
    model_path="$(resolve_model "$MODEL")" || die "Configured model '$MODEL' was not found. Run 'agentio list' and 'agentio settings set model <name>'."
    build_server_args "$model_path"

    umask 077
    {
        echo '#!/usr/bin/env bash'
        printf 'exec %q' "$server_bin"
        printf ' %q' "${SERVER_ARGS[@]}"
        echo
    } > "$LAUNCHER_FILE"
    chmod 700 "$LAUNCHER_FILE"

    {
        echo '[Unit]'
        echo 'Description=AgentIO Local LLM Server (llama.cpp)'
        echo 'After=network.target'
        echo
        echo '[Service]'
        echo 'Type=simple'
        echo 'Environment="PATH=/opt/cuda/bin:/usr/local/bin:/usr/bin:/bin"'
        printf 'ExecStart=%s\n' "$LAUNCHER_FILE"
        echo 'Restart=on-failure'
        echo 'RestartSec=3'
        echo 'StandardOutput=journal'
        echo 'StandardError=journal'
        echo
        echo '[Install]'
        echo 'WantedBy=default.target'
    } > "$SERVICE_FILE"
    systemctl --user daemon-reload
}

start_server() {
    load_settings
    if [ -n "${1:-}" ]; then
        resolve_model "$1" >/dev/null || die "Model '$1' was not found. Run 'agentio list'."
        MODEL="${1#./}"
        save_settings
        warn "Saved '$MODEL' as the selected model. Future starts need no arguments."
    fi
    [ -n "$MODEL" ] || { list_models; die "No model selected. Use 'agentio settings set model <name.gguf>'."; }
    write_service_files
    systemctl --user enable "$SERVICE_NAME" >/dev/null || die "Could not enable the user service."
    systemctl --user restart "$SERVICE_NAME" || die "The service failed to start. Run 'agentio status' or 'agentio logs'."
    sleep 1
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        ok "Server is running at http://$HOST:$PORT with $MODEL."
    else
        systemctl --user status "$SERVICE_NAME" --no-pager
        die "The server exited during startup."
    fi
}

stop_server() {
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        systemctl --user disable --now "$SERVICE_NAME" >/dev/null
        ok "Server stopped."
    else
        warn "Server is already stopped."
    fi
}

status_server() {
    load_settings
    echo "Model: ${MODEL:-not selected}"
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        ok "Server is RUNNING at http://$HOST:$PORT."
        systemctl --user status "$SERVICE_NAME" --no-pager | head -n 7
    else
        warn "Server is STOPPED."
    fi
}

logs_server() {
    info "Following server logs (Ctrl+C to exit)..."
    journalctl --user -u "$SERVICE_NAME" -f
}

download_model() {
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "Usage: agentio download <URL> <filename.gguf>"
    case "$2" in *.gguf|*.GGUF) ;; *) die "The destination name must end in .gguf." ;; esac
    local destination="$MODELS_DIR/${2#./}" partial
    partial="$destination.part"
    mkdir -p "$(dirname "$destination")"
    info "Downloading $2..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -C - -o "$partial" "$1" || die "Download failed; partial data remains at $partial."
    else
        wget -c -O "$partial" "$1" || die "Download failed; partial data remains at $partial."
    fi
    mv "$partial" "$destination"
    ok "Downloaded $2 ($(du -h "$destination" | awk '{print $1}'))."
}

list_models() {
    load_settings
    info "Downloaded models in $MODELS_DIR:"
    local model count=0 size marker selected_found=0
    while IFS= read -r -d '' model; do
        count=$((count + 1))
        size="$(du -h "$MODELS_DIR/$model" | awk '{print $1}')"
        marker=' '
        if [ -n "$MODEL" ] && { [ "$model" = "$MODEL" ] || [ "${model##*/}" = "$MODEL" ]; }; then
            marker='*'
            selected_found=1
        fi
        printf ' %s %-8s %s\n' "$marker" "$size" "$model"
    done < <(find_models)
    [ "$count" -gt 0 ] || echo "  No GGUF models downloaded."
    [ "$selected_found" -eq 1 ] && echo ' * selected model'
}

show_available_flags() {
    local server_bin
    server_bin="$(get_server_binary)" || die "llama-server was not found. Run 'agentio install'."
    echo "Flags supported by the installed llama-server ($server_bin):"
    "$server_bin" --help
}

canonical_key() {
    local key="${1,,}"
    key="${key//-/_}"
    case "$key" in
        model) echo MODEL ;; host) echo HOST ;; port) echo PORT ;; api_key) echo API_KEY ;;
        context|ctx|ctx_size) echo CTX_SIZE ;; gpu_layers|ngl) echo GPU_LAYERS ;;
        threads) echo THREADS ;; threads_batch) echo THREADS_BATCH ;;
        batch|batch_size) echo BATCH_SIZE ;; ubatch|ubatch_size) echo UBATCH_SIZE ;;
        parallel) echo PARALLEL ;; flash_attn) echo FLASH_ATTN ;;
        cache_type_k) echo CACHE_TYPE_K ;; cache_type_v) echo CACHE_TYPE_V ;;
        split_mode) echo SPLIT_MODE ;; tensor_split) echo TENSOR_SPLIT ;; main_gpu) echo MAIN_GPU ;;
        mmap) echo MMAP ;; mlock) echo MLOCK ;; numa) echo NUMA ;;
        cont_batching) echo CONT_BATCHING ;; kv_unified) echo KV_UNIFIED ;;
        swa_full) echo SWA_FULL ;; op_offload) echo OP_OFFLOAD ;; poll) echo POLL ;;
        cpu_mask) echo CPU_MASK ;; cpu_range) echo CPU_RANGE ;;
        cpu_strict) echo CPU_STRICT ;; priority|prio) echo PRIORITY ;;
        cpu_mask_batch) echo CPU_MASK_BATCH ;; cpu_range_batch) echo CPU_RANGE_BATCH ;;
        cpu_strict_batch) echo CPU_STRICT_BATCH ;;
        priority_batch|prio_batch) echo PRIORITY_BATCH ;; poll_batch) echo POLL_BATCH ;;
        defrag_thold) echo DEFRAG_THOLD ;;
        perf) echo PERF ;; kv_offload) echo KV_OFFLOAD ;; repack) echo REPACK ;;
        host_buffer) echo HOST_BUFFER ;; direct_io) echo DIRECT_IO ;; device) echo DEVICE ;;
        cpu_moe) echo CPU_MOE ;; n_cpu_moe) echo N_CPU_MOE ;;
        fit) echo FIT ;; fit_target) echo FIT_TARGET ;; fit_ctx) echo FIT_CTX ;;
        cache_ram) echo CACHE_RAM ;; cache_idle_slots) echo CACHE_IDLE_SLOTS ;;
        cache_prompt) echo CACHE_PROMPT ;; cache_reuse) echo CACHE_REUSE ;;
        threads_http) echo THREADS_HTTP ;;
        *) return 1 ;;
    esac
}

validate_setting() {
    local key="$1" value="$2"
    case "$key" in
        MODEL) resolve_model "$value" >/dev/null || die "Model '$value' was not found. Run 'agentio list'." ;;
        HOST|API_KEY|TENSOR_SPLIT|CPU_MASK|CPU_RANGE|CPU_MASK_BATCH|CPU_RANGE_BATCH|DEVICE) ;;
        PORT) [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "port must be 1..65535." ;;
        CTX_SIZE|THREADS|THREADS_BATCH|BATCH_SIZE|UBATCH_SIZE|PARALLEL|MAIN_GPU|POLL|PRIORITY|N_CPU_MOE|FIT_CTX|CACHE_RAM|CACHE_REUSE|THREADS_HTTP)
            [[ "$value" =~ ^-?[0-9]+$ ]] || die "${key,,} must be an integer." ;;
        GPU_LAYERS) [[ "$value" =~ ^-?[0-9]+$|^(auto|all)$ ]] || die "gpu_layers must be an integer, auto, or all." ;;
        PRIORITY_BATCH) [ -z "$value" ] || [[ "$value" =~ ^[0-3]$ ]] || die "priority_batch must be empty or 0..3." ;;
        POLL_BATCH) [ -z "$value" ] || [[ "$value" =~ ^[01]$ ]] || die "poll_batch must be empty, 0, or 1." ;;
        FIT_TARGET) [[ "$value" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "fit_target must be comma-separated MiB values." ;;
        DEFRAG_THOLD) [ -z "$value" ] || [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || die "defrag_thold must be empty or a number." ;;
        FLASH_ATTN) [[ "$value" =~ ^(auto|on|off)$ ]] || die "flash_attn must be auto, on, or off." ;;
        MMAP|MLOCK|CONT_BATCHING|KV_UNIFIED|SWA_FULL|OP_OFFLOAD|CPU_STRICT|PERF|KV_OFFLOAD|REPACK|HOST_BUFFER|DIRECT_IO|CPU_MOE|FIT|CACHE_IDLE_SLOTS|CACHE_PROMPT)
            [[ "$value" =~ ^(on|off)$ ]] || die "${key,,} must be on or off." ;;
        CPU_STRICT_BATCH) [[ "$value" =~ ^(auto|on|off)$ ]] || die "cpu_strict_batch must be auto, on, or off." ;;
        SPLIT_MODE) [[ "$value" =~ ^(none|layer|row|tensor)$ ]] || die "split_mode must be none, layer, row, or tensor." ;;
        NUMA) [[ "$value" =~ ^(disabled|distribute|isolate|numactl)$ ]] || die "numa must be disabled, distribute, isolate, or numactl." ;;
        CACHE_TYPE_K|CACHE_TYPE_V)
            [[ "$value" =~ ^(f32|f16|bf16|q8_0|q4_0|q4_1|iq4_nl|q5_0|q5_1)$ ]] || die "Unsupported KV cache type '$value'." ;;
    esac
}

apply_preset() {
    local preset="$1"
    case "$preset" in
        balanced)
            CTX_SIZE=8192; GPU_LAYERS=99; BATCH_SIZE=2048; UBATCH_SIZE=512; PARALLEL=1
            FLASH_ATTN=on; CACHE_TYPE_K=f16; CACHE_TYPE_V=f16; MMAP=on; MLOCK=off
            CONT_BATCHING=on; KV_UNIFIED=off; OP_OFFLOAD=on; NUMA=disabled ;;
        throughput)
            CTX_SIZE=8192; GPU_LAYERS=99; BATCH_SIZE=2048; UBATCH_SIZE=1024; PARALLEL=4
            FLASH_ATTN=on; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0; MMAP=on; MLOCK=off
            CONT_BATCHING=on; KV_UNIFIED=on; OP_OFFLOAD=on; NUMA=disabled ;;
        low-vram)
            CTX_SIZE=4096; GPU_LAYERS=20; BATCH_SIZE=512; UBATCH_SIZE=128; PARALLEL=1
            FLASH_ATTN=on; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0; MMAP=on; MLOCK=off
            CONT_BATCHING=on; KV_UNIFIED=off; OP_OFFLOAD=on; NUMA=disabled ;;
        cpu)
            CTX_SIZE=4096; GPU_LAYERS=0; BATCH_SIZE=512; UBATCH_SIZE=128; PARALLEL=1
            FLASH_ATTN=off; CACHE_TYPE_K=f16; CACHE_TYPE_V=f16; MMAP=on; MLOCK=off
            CONT_BATCHING=on; KV_UNIFIED=off; OP_OFFLOAD=on; NUMA=disabled ;;
        *) die "Unknown preset '$preset'. Available: balanced, throughput, low-vram, cpu." ;;
    esac
}

show_settings() {
    load_settings
    cat <<EOF
AgentIO settings ($CONFIG_FILE)

  model            ${MODEL:-<not selected>}
  host / port      $HOST / $PORT
  api_key          $([ -n "$API_KEY" ] && echo '<set>' || echo '<not set>')
  ctx_size         $CTX_SIZE
  gpu_layers       $GPU_LAYERS
  threads          $THREADS (0 = llama.cpp default)
  threads_batch    $THREADS_BATCH (0 = llama.cpp default)
  batch_size       $BATCH_SIZE
  ubatch_size      $UBATCH_SIZE
  parallel         $PARALLEL
  flash_attn       $FLASH_ATTN
  cache_type_k/v   $CACHE_TYPE_K / $CACHE_TYPE_V
  split_mode       $SPLIT_MODE
  tensor_split     ${TENSOR_SPLIT:-<automatic>}
  main_gpu         $MAIN_GPU
  mmap / mlock     $MMAP / $MLOCK
  numa             $NUMA
  cont_batching    $CONT_BATCHING
  kv_unified       $KV_UNIFIED
  swa_full         $SWA_FULL
  op_offload       $OP_OFFLOAD
  poll             $POLL
  cpu_mask         ${CPU_MASK:-<automatic>}
  cpu_range        ${CPU_RANGE:-<automatic>}
  cpu_strict       $CPU_STRICT
  priority         $PRIORITY
  batch CPU mask   ${CPU_MASK_BATCH:-<inherits>}
  batch CPU range  ${CPU_RANGE_BATCH:-<inherits>}
  batch strict     $CPU_STRICT_BATCH
  batch prio/poll  ${PRIORITY_BATCH:-<inherits>} / ${POLL_BATCH:-<inherits>}
  defrag_thold     ${DEFRAG_THOLD:-<automatic>}
  perf timings     $PERF
  kv_offload       $KV_OFFLOAD
  repack           $REPACK
  host_buffer      $HOST_BUFFER
  direct_io        $DIRECT_IO
  device           ${DEVICE:-<automatic>}
  cpu_moe/layers   $CPU_MOE / $N_CPU_MOE
  fit              $FIT (target $FIT_TARGET MiB, min ctx $FIT_CTX)
  cache RAM/reuse  $CACHE_RAM MiB / $CACHE_REUSE tokens
  cache idle slots $CACHE_IDLE_SLOTS
  cache prompt     $CACHE_PROMPT
  HTTP threads     $THREADS_HTTP (0 = llama.cpp default)
  extra args       ${EXTRA_ARGS[*]:-<none>}

Change one:  agentio settings set <key> <value>
Disable one: agentio settings set <boolean-key> off
Clear one:   agentio settings unset <key>
Preset:      agentio settings preset balanced|throughput|low-vram|cpu
Any new llama.cpp flag:
             agentio settings extra set --flag value [--another-flag]
             agentio settings extra clear

Every change regenerates the service and restarts it when it is running.
EOF
}

restart_after_settings_change() {
    save_settings
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        write_service_files
        systemctl --user restart "$SERVICE_NAME" || die "Settings were saved, but the service failed to restart."
        ok "Settings saved; the running model was restarted."
    else
        ok "Settings saved. They will apply on the next 'agentio start'."
    fi
}

settings_command() {
    local action="${1:-show}" key canonical value
    load_settings
    case "$action" in
        show) show_settings ;;
        flags|available) show_available_flags ;;
        set)
            key="${2:-}"; value="${3-}"
            [ -n "$key" ] && [ "$#" -ge 3 ] || die "Usage: agentio settings set <key> <value>"
            canonical="$(canonical_key "$key")" || die "Unknown setting '$key'. Run 'agentio settings' to see all keys."
            validate_setting "$canonical" "$value"
            printf -v "$canonical" '%s' "$value"
            restart_after_settings_change ;;
        unset)
            key="${2:-}"; [ -n "$key" ] || die "Usage: agentio settings unset <key>"
            canonical="$(canonical_key "$key")" || die "Unknown setting '$key'."
            local saved_model="$MODEL" saved_extra=("${EXTRA_ARGS[@]}")
            set_defaults
            value="${!canonical}"
            load_settings
            printf -v "$canonical" '%s' "$value"
            [ "$canonical" = MODEL ] || MODEL="$saved_model"
            EXTRA_ARGS=("${saved_extra[@]}")
            restart_after_settings_change ;;
        preset)
            apply_preset "${2:-}"
            restart_after_settings_change ;;
        reset)
            local old_model="$MODEL"
            set_defaults; MODEL="$old_model"
            restart_after_settings_change ;;
        extra)
            case "${2:-}" in
                set) shift 2; [ "$#" -gt 0 ] || die "Supply one or more llama-server arguments."; EXTRA_ARGS=("$@"); restart_after_settings_change ;;
                add) shift 2; [ "$#" -gt 0 ] || die "Supply one or more llama-server arguments."; EXTRA_ARGS+=("$@"); restart_after_settings_change ;;
                clear) EXTRA_ARGS=(); restart_after_settings_change ;;
                *) die "Usage: agentio settings extra set|add|clear [llama-server arguments...]" ;;
            esac ;;
        *) die "Unknown settings action '$action'." ;;
    esac
}

show_help() {
    cat <<'EOF'
AgentIO - Local LLM Manager (persistent systemd edition)

Commands:
  install | update                         Install dependencies and build llama.cpp
  download <url> <name.gguf>               Download a model safely (resumable)
  list                                     List every downloaded GGUF model
  settings                                 Show all persistent settings and optimization flags
  settings set <key> <value>               Change one setting
  settings unset <key>                     Restore one setting to its default
  settings preset <name>                   Apply balanced, throughput, low-vram, or cpu
  settings flags                           Show every flag supported by installed llama-server
  settings extra set|add|clear [args...]   Configure arbitrary llama-server flags
  settings reset                           Reset optimizations (keeps selected model)
  start [name.gguf]                        Start configured model; optional name selects it
  stop                                     Stop the service
  status                                   Show service status
  logs                                     Follow service logs

Quick start:
  agentio list
  agentio settings set model your-model.gguf
  agentio settings preset balanced
  agentio start
EOF
}

case "${1:-help}" in help|-h|--help) ;; *) ensure_dirs ;; esac

case "${1:-help}" in
    install|setup|update) setup ;;
    download) download_model "${2:-}" "${3:-}" ;;
    start) start_server "${2:-}" ;;
    stop) stop_server ;;
    status) status_server ;;
    logs) logs_server ;;
    list|models) list_models ;;
    settings|config) shift; settings_command "$@" ;;
    help|-h|--help) show_help ;;
    *) die "Unknown command '$1'. Run 'agentio help'." ;;
esac
