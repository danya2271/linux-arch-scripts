#!/bin/bash

# ==============================================================================
# AgentIO - Local LLM Manager for Android Studio (Arch/Ubuntu/Debian)
# ==============================================================================

AGENT_DIR="$HOME/.agentio"
MODELS_DIR="$AGENT_DIR/models"
LLAMA_DIR="$AGENT_DIR/llama.cpp"
PID_FILE="$AGENT_DIR/server.pid"
LOG_FILE="$AGENT_DIR/server.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure directories exist from the start
mkdir -p "$MODELS_DIR"

# ------------------------------------------------------------------------------
# 1. Setup & Installation
# ------------------------------------------------------------------------------

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    fi
}

install_dependencies() {
    detect_os
    echo -e "${BLUE}Installing dependencies for $OS...${NC}"
    if [ "$OS" == "arch" ] || [ "$OS" == "manjaro" ]; then
        sudo pacman -S --needed git cmake make gcc gcc-c++ curl wget cuda base-devel
    elif [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ] || [ "$OS" == "pop" ]; then
        sudo apt-get update
        sudo apt-get install -y build-essential cmake git curl wget nvidia-cuda-toolkit
    fi
}

build_llamacpp() {
    echo -e "${BLUE}Pulling the latest llama.cpp from GitHub...${NC}"
    if [ ! -d "$LLAMA_DIR" ]; then
        git clone https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
    else
        cd "$LLAMA_DIR" && git pull
    fi

    cd "$LLAMA_DIR" || exit

    CMAKE_FLAGS=""
    # Check for NVIDIA CUDA compiler (nvcc)
    if /opt/cuda/bin/nvcc --version &> /dev/null || command -v nvcc &> /dev/null; then
        echo -e "${GREEN}NVIDIA CUDA detected! Building with GPU acceleration...${NC}"
        CMAKE_FLAGS="-DGGML_CUDA=ON"
        if [ "$OS" == "arch" ] || [ "$OS" == "manjaro" ]; then
            export PATH="/opt/cuda/bin:$PATH"
        fi
    else
        echo -e "${YELLOW}No CUDA detected. Building for CPU only...${NC}"
    fi

    cmake -B build $CMAKE_FLAGS
    cmake --build build --config Release -j"$(nproc)"
    echo -e "${GREEN}llama.cpp built successfully!${NC}"
}

setup() {
    # FIX: Copy script globally FIRST before any 'cd' commands change the working directory
    if [[ "$0" != "/usr/local/bin/agentio" && "$0" != "agentio" ]]; then
        echo -e "${BLUE}Installing script globally to /usr/local/bin/agentio...${NC}"
        sudo cp "$0" /usr/local/bin/agentio
        sudo chmod +x /usr/local/bin/agentio
        echo -e "${GREEN}AgentIO installed globally! You can now run 'agentio' from anywhere.${NC}"
    fi

    install_dependencies
    build_llamacpp
    echo -e "\n${YELLOW}Setup complete! Run 'agentio help' for usage.${NC}"
}

# ------------------------------------------------------------------------------
# 2. Server Management
# ------------------------------------------------------------------------------

get_server_binary() {
    local paths=(
        "$LLAMA_DIR/build/bin/llama-server"
        "$LLAMA_DIR/build/llama-server"
        "$LLAMA_DIR/llama-server"
    )
    for p in "${paths[@]}"; do
        if [ -f "$p" ] || [ -x "$p" ]; then
            echo "$p"
            return
        fi
    done
    echo ""
}

start_server() {
    if [ -z "$1" ]; then
        echo "Usage: agentio start <filename.gguf> [context_size] [gpu_layers]"
        echo "Example (For RTX 4060): agentio start omnicoder-9b.gguf 4096 24"
        exit 1
    fi

    MODEL_PATH="$MODELS_DIR/$1"
    CTX="${2:-4096}"
    NGL="${3:-99}" # 99 = Full GPU. Lower this if you run out of VRAM (e.g., 24)

    if [ ! -f "$MODEL_PATH" ]; then
        echo -e "${RED}Model not found: $MODEL_PATH${NC}"
        exit 1
    fi

    SERVER_BIN=$(get_server_binary)
    if [ -z "$SERVER_BIN" ]; then
        echo -e "${RED}Error: llama-server binary not found! Run 'agentio install'${NC}"
        exit 1
    fi

    stop_server > /dev/null 2>&1

    echo -e "${BLUE}Starting model $1 (Context: $CTX | GPU Layers: $NGL)...${NC}"

    nohup "$SERVER_BIN" -m "$MODEL_PATH" -c "$CTX" -ngl "$NGL" --port 8080 > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    # Wait 3 seconds and check if the process is still alive. If not, it crashed.
    sleep 3
    if ! ps -p $(cat "$PID_FILE") > /dev/null; then
        echo -e "${RED}Server crashed! Likely Out of Memory. Check logs:${NC}"
        tail -n 10 "$LOG_FILE"
        rm "$PID_FILE"
        exit 1
    fi

    echo -e "${GREEN}Server successfully started on port 8080! (PID: $(cat "$PID_FILE"))${NC}"
}

stop_server() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null; then
            kill "$PID"
            echo -e "${YELLOW}Server stopped.${NC}"
        else
            echo -e "${YELLOW}Server was not running.${NC}"
        fi
        rm "$PID_FILE"
    else
        pkill -f llama-server && echo -e "${YELLOW}Server processes terminated.${NC}" || echo "No server running."
    fi
}

status_server() {
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        echo -e "${GREEN}Server is RUNNING (PID: $(cat "$PID_FILE"))${NC}"
    else
        echo -e "${RED}Server is STOPPED.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 3. Utilities
# ------------------------------------------------------------------------------

download_model() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: agentio download <URL> <filename.gguf>"
        exit 1
    fi
    echo -e "${BLUE}Downloading $2...${NC}"
    wget -O "$MODELS_DIR/$2" "$1"
    echo -e "${GREEN}Downloaded $2 successfully!${NC}"
}

list_models() {
    echo -e "${BLUE}Available Models in $MODELS_DIR:${NC}"
    ls -lh "$MODELS_DIR" | awk '{print $9, "\t", $5}' | grep "\.gguf" || echo "No models downloaded."
}

# ------------------------------------------------------------------------------
# CLI Router
# ------------------------------------------------------------------------------

case "$1" in
    install|setup|update) setup ;;
    download) download_model "$2" "$3" ;;
    start) start_server "$2" "$3" "$4" ;;
    stop) stop_server ;;
    status) status_server ;;
    list) list_models ;;
    *)
        echo -e "${BLUE}AgentIO - Local LLM Manager${NC}"
        echo "Commands:"
        echo "  install / update                     - Compile latest llama.cpp with CUDA support"
        echo "  download <url> <name.gguf>           - Download a model"
        echo "  start <name.gguf> [context] [layers] - Start local LLM (e.g. start model.gguf 4096 24)"
        echo "  stop                                 - Stop local LLM"
        echo "  status                               - Check if running"
        echo "  list                                 - List downloaded models"
        echo "  help                                 - Show this message"
        ;;
esac
