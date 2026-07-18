#!/usr/bin/env bash

# AgentIO - persistent llama.cpp + TurboQuant model and systemd service manager.

set -o pipefail

AGENT_DIR="${AGENTIO_HOME:-$HOME/.agentio}"
MODELS_DIR="$AGENT_DIR/models"
LLAMA_DIR="$AGENT_DIR/llama.cpp"
LLAMA_REPO="${AGENTIO_LLAMA_REPO:-https://github.com/TheTom/llama-cpp-turboquant.git}"
LLAMA_BRANCH="${AGENTIO_LLAMA_BRANCH:-feature/turboquant-kv-cache}"
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

# Model/runtime optimization defaults. TurboQuant's asymmetric q8_0/turbo3 KV
# cache is the fork's recommended general-purpose starting point. "auto" is an
# AgentIO value: the corresponding llama-server argument is omitted so --fit
# can choose it from the model metadata and available device memory.
set_optimization_defaults() {
    PRESET="balanced"
    CTX_SIZE="auto"
    GPU_LAYERS="auto"
    THREADS="0"
    THREADS_BATCH="0"
    BATCH_SIZE="2048"
    UBATCH_SIZE="512"
    PARALLEL="1"
    FLASH_ATTN="auto"
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="turbo3"
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
}

# Values are persisted as shell-escaped assignments in a user-only file.
# EXTRA_ARGS is an array so arguments containing spaces survive.
set_defaults() {
    MODEL=""
    HOST="127.0.0.1"
    PORT="8080"
    API_KEY=""
    set_optimization_defaults
    EXTRA_ARGS=()
}

load_settings() {
    set_defaults
    if [ -f "$CONFIG_FILE" ]; then
        # Configurations written before presets were tracked should not claim
        # to be the new balanced preset merely because PRESET was absent.
        if ! grep -q '^PRESET=' "$CONFIG_FILE"; then
            PRESET="custom"
        fi
        # The file is created mode 600 and every value is written with printf %q.
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
    # Older AgentIO versions serialized an empty array as one empty argument.
    # Normalize it so llama-server never receives a trailing blank argument.
    if [ "${#EXTRA_ARGS[@]}" -eq 1 ] && [ -z "${EXTRA_ARGS[0]}" ]; then
        EXTRA_ARGS=()
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
        write_assignment PRESET "$PRESET"
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
        printf 'EXTRA_ARGS=('
        if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
            printf ' %q' "${EXTRA_ARGS[@]}"
        fi
        echo ' )'
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
        arch|manjaro) sudo pacman -S --needed git cmake make gcc curl wget cuda base-devel npm ;;
        ubuntu|debian|pop) sudo apt-get update && sudo apt-get install -y build-essential cmake git curl wget nvidia-cuda-toolkit npm ;;
        *) die "Unsupported distribution '$OS'. Install Git, CMake, a C++ compiler, curl/wget, and optionally CUDA manually." ;;
    esac
}

build_llamacpp() {
    detect_os
    info "Updating llama.cpp + TurboQuant from $LLAMA_REPO..."
    if [ ! -d "$LLAMA_DIR/.git" ]; then
        git clone --depth=1 --branch "$LLAMA_BRANCH" "$LLAMA_REPO" "$LLAMA_DIR" || exit 1
    else
        local origin current_branch
        origin="$(git -C "$LLAMA_DIR" remote get-url origin 2>/dev/null || true)"
        current_branch="$(git -C "$LLAMA_DIR" branch --show-current 2>/dev/null || true)"

        if [ "$origin" != "$LLAMA_REPO" ]; then
            [ -z "$(git -C "$LLAMA_DIR" status --porcelain)" ] ||
                die "$LLAMA_DIR has local changes. Commit or remove them before migrating it to TurboQuant."
            warn "Migrating the existing llama.cpp checkout from $origin to TurboQuant."
            git -C "$LLAMA_DIR" remote set-url origin "$LLAMA_REPO" || exit 1
            git -C "$LLAMA_DIR" fetch --depth=1 origin "$LLAMA_BRANCH" || exit 1
            git -C "$LLAMA_DIR" checkout -B "$LLAMA_BRANCH" FETCH_HEAD || exit 1
        else
            if [ "$current_branch" != "$LLAMA_BRANCH" ]; then
                [ -z "$(git -C "$LLAMA_DIR" status --porcelain)" ] ||
                    die "$LLAMA_DIR has local changes. Commit or remove them before switching to $LLAMA_BRANCH."
                git -C "$LLAMA_DIR" fetch --depth=1 origin "$LLAMA_BRANCH" || exit 1
                git -C "$LLAMA_DIR" checkout -B "$LLAMA_BRANCH" FETCH_HEAD || exit 1
            else
                git -C "$LLAMA_DIR" pull --ff-only origin "$LLAMA_BRANCH" || exit 1
            fi
        fi
    fi

    local cmake_flags=()
    if [ -x /opt/cuda/bin/nvcc ] || command -v nvcc >/dev/null 2>&1; then
        ok "NVIDIA CUDA detected; enabling GPU acceleration."
        cmake_flags+=(-DGGML_CUDA=ON)
        [ -d /opt/cuda/bin ] && export PATH="/opt/cuda/bin:$PATH"
    else
        warn "CUDA was not detected; building for CPU only."
    fi
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DCMAKE_BUILD_TYPE=Release "${cmake_flags[@]}" || exit 1
    cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)" || exit 1
    ok "llama.cpp + TurboQuant built successfully."
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

get_quantize_binary() {
    local path
    for path in \
        "$LLAMA_DIR/build/bin/llama-quantize" \
        "$LLAMA_DIR/build/llama-quantize" \
        "$LLAMA_DIR/llama-quantize"; do
        [ -x "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

ensure_user_linger() {
    local user linger
    command -v loginctl >/dev/null 2>&1 ||
        die "loginctl was not found; AgentIO needs systemd user lingering to stay running after logout."

    user="$(id -un)" || die "Could not determine the current user."
    linger="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"
    [ "$linger" = yes ] && return

    info "Enabling systemd user lingering so AgentIO stays running after logout..."
    sudo loginctl enable-linger "$user" ||
        die "Could not enable user lingering. Run 'sudo loginctl enable-linger $user', then try again."

    linger="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"
    [ "$linger" = yes ] ||
        die "User lingering is still disabled. Run 'sudo loginctl enable-linger $user', then try again."
    ok "Systemd user lingering enabled."
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
        --batch-size "$BATCH_SIZE" --ubatch-size "$UBATCH_SIZE"
        --parallel "$PARALLEL" --cache-type-k "$CACHE_TYPE_K"
        --cache-type-v "$CACHE_TYPE_V" --split-mode "$SPLIT_MODE"
        --main-gpu "$MAIN_GPU" --poll "$POLL" --prio "$PRIORITY"
    )
    # Omitting these arguments is significant: TurboQuant's --fit logic only
    # adjusts model context and GPU offload when llama-server sees defaults.
    [ "$CTX_SIZE" != auto ] && SERVER_ARGS+=(-c "$CTX_SIZE")
    [ "$GPU_LAYERS" != auto ] && SERVER_ARGS+=(-ngl "$GPU_LAYERS")
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
        echo 'Description=AgentIO Local LLM Server (llama.cpp + TurboQuant)'
        echo 'After=network.target'
        echo
        echo '[Service]'
        echo 'Type=simple'
        echo 'Environment="PATH=/opt/cuda/bin:/usr/local/bin:/usr/bin:/bin"'
        printf 'ExecStart=%s\n' "$LAUNCHER_FILE"
        echo 'Restart=always'
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
    ensure_user_linger
    write_service_files
    systemctl --user enable "$SERVICE_NAME" >/dev/null || die "Could not enable the user service."
    systemctl --user restart "$SERVICE_NAME" || die "The service failed to start. Run 'agentio status' or 'agentio logs'."
    sleep 1
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        ok "Server is running at http://$HOST:$PORT with $MODEL."
    else
        systemctl --user status "$SERVICE_NAME" --no-pager
        systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
        die "The server exited during startup."
    fi
}

stop_server() {
    local state
    state="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
    systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    if [ "$state" = inactive ] || [ "$state" = unknown ]; then
        warn "Server was already stopped; its autostart is disabled."
    else
        ok "Server stopped and its restart loop was disabled."
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

quantize_model() {
    [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] ||
        die "Usage: agentio quantize <source.gguf> <output.gguf> <tq4|tq3>"
    local source_path destination partial quant_type quantize_bin
    source_path="$(resolve_model "$1")" || die "Source model '$1' was not found. Run 'agentio list'."
    case "$2" in
        /*|..|../*|*/..|*/../*) die "Output must be a relative path inside $MODELS_DIR." ;;
        *.gguf|*.GGUF) ;;
        *) die "The output name must end in .gguf." ;;
    esac
    destination="$MODELS_DIR/${2#./}"
    partial="$destination.part"
    [ ! -e "$destination" ] && [ ! -e "$partial" ] || die "Output or partial output already exists: $destination"
    case "${3,,}" in
        tq4|tq4_1s) quant_type="TQ4_1S" ;;
        tq3|tq3_1s) quant_type="TQ3_1S" ;;
        *) die "Unknown TurboQuant weight format '$3'. Available: tq4 (safer) or tq3 (smaller)." ;;
    esac
    quantize_bin="$(get_quantize_binary)" || die "llama-quantize was not found. Run 'agentio install'."
    mkdir -p "$(dirname "$destination")"
    info "Quantizing $1 to $quant_type..."
    "$quantize_bin" "$source_path" "$partial" "$quant_type" || die "Weight quantization failed; any partial data remains at $partial."
    [ -s "$partial" ] || die "Weight quantization produced no output at $partial."
    mv "$partial" "$destination" || die "Could not finalize $destination."
    ok "Created ${destination#"$MODELS_DIR/"} ($(du -h "$destination" | awk '{print $1}'))."
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

show_available_devices() {
    local server_bin
    server_bin="$(get_server_binary)" || die "llama-server was not found. Run 'agentio install'."
    "$server_bin" --list-devices
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
        HOST) [ -n "$value" ] || die "host cannot be empty." ;;
        API_KEY|CPU_MASK|CPU_MASK_BATCH|DEVICE) ;;
        CPU_RANGE|CPU_RANGE_BATCH)
            [ -z "$value" ] || [[ "$value" =~ ^[0-9]+-[0-9]+$ ]] || die "${key,,} must be empty or a CPU range such as 0-7." ;;
        TENSOR_SPLIT)
            [ -z "$value" ] || [[ "$value" =~ ^[0-9]+([.][0-9]+)?([,/][0-9]+([.][0-9]+)?)*$ ]] ||
                die "tensor_split must be empty or proportions such as 3,1." ;;
        PORT) [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "port must be 1..65535." ;;
        CTX_SIZE)
            [ "$value" = auto ] || { [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ]; } || die "ctx_size must be auto or an integer >= 1." ;;
        GPU_LAYERS)
            [[ "$value" =~ ^(auto|all)$ ]] || { [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 0 ]; } || die "gpu_layers must be auto, all, or an integer >= 0." ;;
        THREADS|THREADS_BATCH|THREADS_HTTP)
            [[ "$value" =~ ^[0-9]+$ ]] || die "${key,,} must be 0 (automatic) or an integer >= 1." ;;
        BATCH_SIZE|UBATCH_SIZE)
            [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] || die "${key,,} must be an integer >= 1." ;;
        PARALLEL)
            if ! [[ "$value" =~ ^-?[0-9]+$ ]] || { [ "$value" -ne -1 ] && [ "$value" -lt 1 ]; }; then
                die "parallel must be -1 (automatic) or an integer >= 1."
            fi ;;
        MAIN_GPU|N_CPU_MOE|FIT_CTX|CACHE_REUSE)
            [[ "$value" =~ ^[0-9]+$ ]] || die "${key,,} must be an integer >= 0." ;;
        CACHE_RAM)
            [[ "$value" =~ ^-?[0-9]+$ ]] && [ "$value" -ge -1 ] || die "cache_ram must be -1 (unlimited), 0 (off), or a positive MiB value." ;;
        POLL)
            [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -le 100 ] || die "poll must be 0..100." ;;
        PRIORITY)
            [[ "$value" =~ ^-?[0-9]+$ ]] && [ "$value" -ge -1 ] && [ "$value" -le 3 ] || die "priority must be -1..3." ;;
        PRIORITY_BATCH) [ -z "$value" ] || [[ "$value" =~ ^[0-3]$ ]] || die "priority_batch must be empty or 0..3." ;;
        POLL_BATCH) [ -z "$value" ] || [[ "$value" =~ ^[01]$ ]] || die "poll_batch must be empty, 0, or 1." ;;
        FIT_TARGET) [[ "$value" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "fit_target must be one or more comma-separated MiB values." ;;
        DEFRAG_THOLD) [ -z "$value" ] || [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || die "defrag_thold must be empty or a number." ;;
        FLASH_ATTN) [[ "$value" =~ ^(auto|on|off)$ ]] || die "flash_attn must be auto, on, or off." ;;
        MMAP|MLOCK|CONT_BATCHING|KV_UNIFIED|SWA_FULL|OP_OFFLOAD|CPU_STRICT|PERF|KV_OFFLOAD|REPACK|HOST_BUFFER|DIRECT_IO|CPU_MOE|FIT|CACHE_IDLE_SLOTS|CACHE_PROMPT)
            [[ "$value" =~ ^(on|off)$ ]] || die "${key,,} must be on or off." ;;
        CPU_STRICT_BATCH) [[ "$value" =~ ^(auto|on|off)$ ]] || die "cpu_strict_batch must be auto, on, or off." ;;
        SPLIT_MODE) [[ "$value" =~ ^(none|layer|row|tensor)$ ]] || die "split_mode must be none, layer, row, or tensor." ;;
        NUMA) [[ "$value" =~ ^(disabled|distribute|isolate|numactl)$ ]] || die "numa must be disabled, distribute, isolate, or numactl." ;;
        CACHE_TYPE_K|CACHE_TYPE_V)
            [[ "$value" =~ ^(f32|f16|bf16|q8_0|q4_0|q4_1|iq4_nl|q5_0|q5_1|turbo2|turbo3|turbo4)$ ]] ||
                die "Unsupported KV cache type '$value'. Run 'agentio settings describe cache_type_k' for available values." ;;
    esac
}

validate_configuration() {
    [ "$UBATCH_SIZE" -le "$BATCH_SIZE" ] || die "ubatch_size ($UBATCH_SIZE) cannot exceed batch_size ($BATCH_SIZE)."
    if [ "$SPLIT_MODE" = tensor ]; then
        [[ "$CACHE_TYPE_K" =~ ^(f32|f16|bf16)$ ]] && [[ "$CACHE_TYPE_V" =~ ^(f32|f16|bf16)$ ]] ||
            die "split_mode=tensor currently requires an unquantized KV cache (f32, f16, or bf16 for both K and V)."
    fi
}

mark_custom_if_optimization() {
    case "$1" in MODEL|HOST|PORT|API_KEY) ;; *) PRESET="custom" ;; esac
}

apply_preset() {
    local preset="$1"
    set_optimization_defaults
    case "$preset" in
        quality|safe)
            PRESET="quality"
            CACHE_TYPE_K=f16; CACHE_TYPE_V=turbo4 ;;
        balanced)
            PRESET="balanced" ;;
        memory|aggressive)
            PRESET="memory"
            BATCH_SIZE=1024; UBATCH_SIZE=256
            CACHE_TYPE_K=q8_0; CACHE_TYPE_V=turbo2 ;;
        throughput)
            PRESET="throughput"
            UBATCH_SIZE=1024; PARALLEL=4; KV_UNIFIED=on ;;
        low-vram)
            PRESET="low-vram"
            BATCH_SIZE=512; UBATCH_SIZE=128; FIT_TARGET=512
            CACHE_TYPE_K=q8_0; CACHE_TYPE_V=turbo2 ;;
        cpu)
            PRESET="cpu"
            GPU_LAYERS=0; BATCH_SIZE=512; UBATCH_SIZE=128
            CACHE_TYPE_K=q8_0; CACHE_TYPE_V=turbo3; OP_OFFLOAD=off ;;
        *) die "Unknown preset '$preset'. Run 'agentio settings presets' to see: quality, balanced, memory, throughput, low-vram, cpu." ;;
    esac
    validate_configuration
}

show_presets() {
    cat <<'EOF'
TurboQuant optimization presets

  quality      Safest first run for a new or quant-sensitive model.
               K=f16, V=turbo4; light V compression and highest fidelity.

  balanced     Recommended general-purpose default.
               K=q8_0, V=turbo3; usually a 3-4x total KV-cache reduction.

  memory       Aggressive long-context/RAM-saving profile. Validate quality.
               K=q8_0, V=turbo2; Boundary V protection activates automatically.

  throughput   Balanced compression plus four concurrent server slots and a
               larger physical batch. Best when serving concurrent requests.

  low-vram     Aggressive KV compression, small batches, and a 512 MiB fit
               margin. Lets --fit place as much of the model as practical.

  cpu          CPU-only model placement with smaller batches and balanced
               TurboQuant KV compression.

All presets use model-derived context and automatic GPU placement through
TurboQuant's --fit logic. Compression quality is model-dependent: begin with
quality for an unfamiliar model, then try balanced before memory.

Aliases: safe=quality, aggressive=memory
Apply:   agentio settings preset <name>
EOF
}

describe_one_setting() {
    local requested="$1" canonical display values description
    canonical="$(canonical_key "$requested")" || die "Unknown setting '$requested'."
    case "$canonical" in
        MODEL) display=model; values='downloaded .gguf name or relative path'; description='Model selected from the AgentIO models directory.' ;;
        HOST) display=host; values='IP address or hostname'; description='HTTP listen address. Use 127.0.0.1 for local-only access or 0.0.0.0 for all interfaces.' ;;
        PORT) display=port; values='1..65535'; description='HTTP listen port.' ;;
        API_KEY) display=api_key; values='any string; empty disables'; description='Bearer API key. Stored mode 600 and hidden in settings output.' ;;
        CTX_SIZE) display=ctx_size; values='auto | integer >= 1'; description='Total context tokens. auto loads the model maximum and lets --fit reduce it if memory is tight.' ;;
        GPU_LAYERS) display=gpu_layers; values='auto | all | integer >= 0'; description='Layers placed on accelerators. auto lets --fit choose; 0 is CPU-only.' ;;
        THREADS) display=threads; values='0 | integer >= 1'; description='CPU generation threads. 0 leaves the fork default/hardware detection in control.' ;;
        THREADS_BATCH) display=threads_batch; values='0 | integer >= 1'; description='CPU prompt/batch threads. 0 inherits the generation-thread behavior.' ;;
        BATCH_SIZE) display=batch_size; values='integer >= 1 (>=32 recommended)'; description='Logical maximum prompt batch. Larger can improve prefill throughput but needs more memory.' ;;
        UBATCH_SIZE) display=ubatch_size; values='1..batch_size (>=32 recommended)'; description='Physical batch processed at once. Lower this first when compute buffers do not fit.' ;;
        PARALLEL) display=parallel; values='-1 (auto) | integer >= 1'; description='Number of server slots/concurrent sequences. More slots increase throughput and KV memory use.' ;;
        FLASH_ATTN) display=flash_attn; values='auto | on | off'; description='Flash Attention policy. auto is portable and automatically uses TurboQuant kernels where supported.' ;;
        CACHE_TYPE_K) display=cache_type_k; values='f32 | f16 | bf16 | q8_0 | q5_0 | q5_1 | q4_0 | q4_1 | iq4_nl | turbo4 | turbo3 | turbo2'; description='Key-cache precision. K is quality-sensitive: prefer f16 or q8_0; turbo K requires model-specific validation.' ;;
        CACHE_TYPE_V) display=cache_type_v; values='f32 | f16 | bf16 | q8_0 | q5_0 | q5_1 | q4_0 | q4_1 | iq4_nl | turbo4 | turbo3 | turbo2'; description='Value-cache precision. TurboQuant ladder: turbo4 is safest, turbo3 balanced, turbo2 smallest/aggressive.' ;;
        SPLIT_MODE) display=split_mode; values='none | layer | row | tensor'; description='Multi-GPU split. layer is the portable default; tensor is experimental and requires unquantized K/V cache.' ;;
        TENSOR_SPLIT) display=tensor_split; values='empty (automatic) | proportions such as 3,1'; description='Relative model allocation across GPUs.' ;;
        MAIN_GPU) display=main_gpu; values='integer >= 0'; description='Primary GPU index for split mode none, or intermediate/KV work in row mode.' ;;
        MMAP) display=mmap; values='on | off'; description='Memory-map model weights for faster loading and OS page-cache sharing.' ;;
        MLOCK) display=mlock; values='on | off'; description='Keep mapped model pages in RAM instead of allowing swap/compression; requires enough RAM and limits.' ;;
        NUMA) display=numa; values='disabled | distribute | isolate | numactl'; description='NUMA placement strategy. Leave disabled on ordinary single-socket systems.' ;;
        CONT_BATCHING) display=cont_batching; values='on | off'; description='Insert new requests while other requests decode; normally keep on for the server.' ;;
        KV_UNIFIED) display=kv_unified; values='on | off'; description='Share one KV buffer across sequences. Useful for dynamic multi-slot workloads.' ;;
        SWA_FULL) display=swa_full; values='on | off'; description='Allocate full-size sliding-window-attention cache. Improves some SWA workflows at substantial memory cost.' ;;
        OP_OFFLOAD) display=op_offload; values='on | off'; description='Offload eligible host tensor operations to the accelerator.' ;;
        POLL) display=poll; values='0..100'; description='CPU worker polling level. Higher can reduce latency while consuming more idle CPU; 0 disables polling.' ;;
        CPU_MASK) display=cpu_mask; values='empty | hexadecimal affinity mask'; description='Generation CPU affinity mask; mutually alternative to cpu_range.' ;;
        CPU_RANGE) display=cpu_range; values='empty | lo-hi, for example 0-7'; description='Generation CPU affinity range; mutually alternative to cpu_mask.' ;;
        CPU_STRICT) display=cpu_strict; values='on | off'; description='Require strict generation-thread placement on the selected CPUs.' ;;
        PRIORITY) display=priority; values='-1 low | 0 normal | 1 medium | 2 high | 3 realtime'; description='Generation worker scheduling priority. High/realtime may require privileges and can hurt responsiveness.' ;;
        CPU_MASK_BATCH) display=cpu_mask_batch; values='empty (inherit) | hexadecimal affinity mask'; description='Prompt/batch CPU affinity mask.' ;;
        CPU_RANGE_BATCH) display=cpu_range_batch; values='empty (inherit) | lo-hi'; description='Prompt/batch CPU affinity range.' ;;
        CPU_STRICT_BATCH) display=cpu_strict_batch; values='auto (inherit) | on | off'; description='Strict placement policy for prompt/batch threads.' ;;
        PRIORITY_BATCH) display=priority_batch; values='empty (inherit) | 0..3'; description='Prompt/batch worker priority.' ;;
        POLL_BATCH) display=poll_batch; values='empty (inherit) | 0 | 1'; description='Disable or enable polling for prompt/batch workers.' ;;
        DEFRAG_THOLD) display=defrag_thold; values='empty (recommended) | number'; description='Deprecated no-op retained for old configs; leave empty.' ;;
        PERF) display=perf; values='on | off'; description='Collect internal libllama timing counters; useful for diagnostics with a small measurement overhead.' ;;
        KV_OFFLOAD) display=kv_offload; values='on | off'; description='Keep KV cache on the accelerator when possible. Disable to save VRAM at a performance cost.' ;;
        REPACK) display=repack; values='on | off'; description='Allow runtime weight repacking into faster backend-specific layouts.' ;;
        HOST_BUFFER) display=host_buffer; values='on | off'; description='Use the normal host staging buffer. off passes --no-host for advanced extra-buffer paths.' ;;
        DIRECT_IO) display=direct_io; values='on | off'; description='Bypass the OS file cache when supported. Usually leave off unless page-cache pressure is a known issue.' ;;
        DEVICE) display=device; values='empty (automatic) | comma-separated device names'; description='Accelerators used for offload. Discover exact names with agentio settings devices.' ;;
        CPU_MOE) display=cpu_moe; values='on | off'; description='Keep all Mixture-of-Experts expert weights on CPU to reduce VRAM use.' ;;
        N_CPU_MOE) display=n_cpu_moe; values='integer >= 0'; description='Keep expert weights for the first N MoE layers on CPU; 0 disables partial placement.' ;;
        FIT) display=fit; values='on | off'; description='Adapt automatic context/GPU placement to free memory. Works best with ctx_size=auto and gpu_layers=auto.' ;;
        FIT_TARGET) display=fit_target; values='MiB or comma-separated MiB per device'; description='Free-memory safety margin retained on each accelerator by --fit.' ;;
        FIT_CTX) display=fit_ctx; values='integer >= 0'; description='Smallest context size --fit may choose when reducing model-derived context.' ;;
        CACHE_RAM) display=cache_ram; values='-1 unlimited | 0 off | positive MiB'; description='RAM budget for reusable prompt-cache entries; separate from the active KV cache.' ;;
        CACHE_IDLE_SLOTS) display=cache_idle_slots; values='on | off'; description='Move idle slots into the prompt cache for later reuse; requires cache_ram.' ;;
        CACHE_PROMPT) display=cache_prompt; values='on | off'; description='Reuse matching prompt prefixes across requests.' ;;
        CACHE_REUSE) display=cache_reuse; values='0 off | integer tokens >= 1'; description='Minimum matching chunk considered for KV-shift cache reuse; requires cache_prompt.' ;;
        THREADS_HTTP) display=threads_http; values='0 (fork default) | integer >= 1'; description='HTTP request-processing thread count.' ;;
    esac
    printf '%-18s %s\n' "$display" "$values"
    printf '  %s\n' "$description"
}

show_setting_descriptions() {
    if [ -n "${1:-}" ]; then
        describe_one_setting "$1"
        return
    fi
    cat <<'EOF'
AgentIO setting reference
Values shown as "empty" are restored with: agentio settings unset <key>

EOF
    local key
    for key in \
        model host port api_key ctx_size gpu_layers threads threads_batch batch_size ubatch_size parallel \
        flash_attn cache_type_k cache_type_v split_mode tensor_split main_gpu mmap mlock numa \
        cont_batching kv_unified swa_full op_offload poll cpu_mask cpu_range cpu_strict priority \
        cpu_mask_batch cpu_range_batch cpu_strict_batch priority_batch poll_batch defrag_thold perf \
        kv_offload repack host_buffer direct_io device cpu_moe n_cpu_moe fit fit_target fit_ctx \
        cache_ram cache_idle_slots cache_prompt cache_reuse threads_http; do
        describe_one_setting "$key"
        echo
    done
}

show_settings() {
    load_settings
    cat <<EOF
AgentIO settings ($CONFIG_FILE)

  preset           $PRESET
  model            ${MODEL:-<not selected>}
  host / port      $HOST / $PORT
  api_key          $([ -n "$API_KEY" ] && echo '<set>' || echo '<not set>')
  ctx_size         $CTX_SIZE$([ "$CTX_SIZE" = auto ] && echo ' (model maximum, adjusted by fit)')
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
  extra args       $([ "${#EXTRA_ARGS[@]}" -gt 0 ] && printf '%s' "${EXTRA_ARGS[*]}" || echo '<none>')

Change one:  agentio settings set <key> <value>
Disable one: agentio settings set <boolean-key> off
Clear one:   agentio settings unset <key>
Presets:     agentio settings presets
Describe:    agentio settings describe [key]
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
        devices) show_available_devices ;;
        presets) show_presets ;;
        describe|help) show_setting_descriptions "${2:-}" ;;
        set)
            key="${2:-}"; value="${3-}"
            [ -n "$key" ] && [ "$#" -ge 3 ] || die "Usage: agentio settings set <key> <value>"
            canonical="$(canonical_key "$key")" || die "Unknown setting '$key'. Run 'agentio settings' to see all keys."
            validate_setting "$canonical" "$value"
            printf -v "$canonical" '%s' "$value"
            validate_configuration
            mark_custom_if_optimization "$canonical"
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
            validate_configuration
            mark_custom_if_optimization "$canonical"
            restart_after_settings_change ;;
        preset)
            apply_preset "${2:-}"
            case "$PRESET" in
                memory|low-vram) warn "This preset uses turbo2 V cache. Validate output quality for this model before production use." ;;
            esac
            restart_after_settings_change ;;
        reset)
            set_optimization_defaults
            restart_after_settings_change ;;
        extra)
            case "${2:-}" in
                set) shift 2; [ "$#" -gt 0 ] || die "Supply one or more llama-server arguments."; EXTRA_ARGS=("$@"); PRESET=custom; restart_after_settings_change ;;
                add) shift 2; [ "$#" -gt 0 ] || die "Supply one or more llama-server arguments."; EXTRA_ARGS+=("$@"); PRESET=custom; restart_after_settings_change ;;
                clear) EXTRA_ARGS=(); PRESET=custom; restart_after_settings_change ;;
                *) die "Usage: agentio settings extra set|add|clear [llama-server arguments...]" ;;
            esac ;;
        *) die "Unknown settings action '$action'." ;;
    esac
}

show_help() {
    cat <<'EOF'
AgentIO - llama.cpp + TurboQuant local LLM manager

Commands:
  install | update                         Install/update the TurboQuant fork
  download <url> <name.gguf>               Download a model safely (resumable)
  quantize <input> <output> <tq4|tq3>      Create a TurboQuant weight GGUF
  list                                     List every downloaded GGUF model
  settings                                 Show all persistent settings and optimization flags
  settings set <key> <value>               Change one setting
  settings unset <key>                     Restore one setting to its default
  settings presets                         Explain every optimization preset
  settings preset <name>                   Apply quality, balanced, memory, throughput,
                                           low-vram, or cpu
  settings describe [key]                  Explain settings and accepted values
  settings devices                         List available accelerator device names
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
    quantize) quantize_model "${2:-}" "${3:-}" "${4:-}" ;;
    start) start_server "${2:-}" ;;
    stop) stop_server ;;
    status) status_server ;;
    logs) logs_server ;;
    list|models) list_models ;;
    settings|config) shift; settings_command "$@" ;;
    help|-h|--help) show_help ;;
    *) die "Unknown command '$1'. Run 'agentio help'." ;;
esac
