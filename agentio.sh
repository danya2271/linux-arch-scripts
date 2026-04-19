#!/bin/bash

# ==============================================================================
# AgentIO - Local LLM Manager for Android Studio (Arch/Ubuntu/Debian)
# ==============================================================================

AGENT_DIR="$HOME/.agentio"
MODELS_DIR="$AGENT_DIR/models"
LLAMA_DIR="$AGENT_DIR/llama.cpp"

# Systemd specific variables
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="agentio.service"
SERVICE_FILE="$SYSTEMD_DIR/$SERVICE_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure directories exist from the start
mkdir -p "$MODELS_DIR"
mkdir -p "$SYSTEMD_DIR"

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
# 2. Server Management (Systemd)
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
        echo "Usage: agentio start <filename.gguf> [context_size] [gpu_layers] [api_key]"
        echo "Example: agentio start omnicoder-9b.gguf 4096 24 my_secret_key"
        exit 1
    fi

    MODEL_PATH="$MODELS_DIR/$1"
    CTX="${2:-4096}"
    NGL="${3:-99}"
    API_KEY="$4"

    if [ ! -f "$MODEL_PATH" ]; then
        echo -e "${RED}Model not found: $MODEL_PATH${NC}"
        exit 1
    fi

    SERVER_BIN=$(get_server_binary)
    if [ -z "$SERVER_BIN" ]; then
        echo -e "${RED}Error: llama-server binary not found! Run 'agentio install'${NC}"
        exit 1
    fi

    API_KEY_FLAG=""
    if [ -n "$API_KEY" ]; then
        API_KEY_FLAG="--api-key $API_KEY"
    fi

    echo -e "${BLUE}Configuring Systemd service for $1...${NC}"

    # Dynamically generate the systemd service file
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=AgentIO Local LLM Server (llama.cpp)
After=network.target

[Service]
Type=simple
Environment="PATH=/opt/cuda/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$SERVER_BIN -m "$MODEL_PATH" -c "$CTX" -ngl "$NGL" --port 8080 $API_KEY_FLAG
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    # Reload systemd, stop existing service, and start the new one
    systemctl --user daemon-reload
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null
    systemctl --user start "$SERVICE_NAME"
    systemctl --user enable "$SERVICE_NAME" > /dev/null 2>&1

    # Check if the process started successfully
    sleep 2
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Server successfully started on port 8080 via Systemd!${NC}"
        if [ -n "$API_KEY" ]; then
            echo -e "${YELLOW}API Key protection is ENABLED.${NC}"
        fi
        echo -e "To view live logs, run: ${BLUE}agentio logs${NC}"
    else
        echo -e "${RED}Server crashed or failed to start. Check logs:${NC}"
        systemctl --user status "$SERVICE_NAME" --no-pager
        exit 1
    fi
}

stop_server() {
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        systemctl --user stop "$SERVICE_NAME"
        systemctl --user disable "$SERVICE_NAME" > /dev/null 2>&1
        echo -e "${YELLOW}Systemd server stopped.${NC}"
    else
        echo -e "${YELLOW}Server was not running.${NC}"
    fi
}

status_server() {
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Server is RUNNING.${NC}"
        systemctl --user status "$SERVICE_NAME" --no-pager | head -n 5
    else
        echo -e "${RED}Server is STOPPED.${NC}"
    fi
}

logs_server() {
    echo -e "${BLUE}Following server logs (Press Ctrl+C to exit)...${NC}"
    journalctl --user -u "$SERVICE_NAME" -f
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
    start) start_server "$2" "$3" "$4" "$5" ;;
    stop) stop_server ;;
    status) status_server ;;
    logs) logs_server ;;
    list) list_models ;;
    *)
        echo -e "${BLUE}AgentIO - Local LLM Manager (Systemd Edition)${NC}"
        echo "Commands:"
        echo "  install / update                               - Compile latest llama.cpp with CUDA support"
        echo "  download <url> <name.gguf>                     - Download a model"
        echo "  start <name.gguf> [context] [layers] [api_key] - Start LLM Systemd service"
        echo "                                                   (e.g. start model.gguf 4096 99 my_secret_key)"
        echo "  stop                                           - Stop LLM Systemd service"
        echo "  status                                         - Check if service is running"
        echo "  logs                                           - View live server logs (journalctl)"
        echo "  list                                           - List downloaded models"
        echo "  help                                           - Show this message"
        ;;
esac
