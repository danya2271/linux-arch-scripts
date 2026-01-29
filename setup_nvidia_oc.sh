#!/bin/bash

# ==============================================================================
# CONFIGURATION & DEFAULTS
# ==============================================================================

# Variables for CLI arguments (optional)
CLI_INDEX=""
CLI_CORE=""
CLI_MEM=""
CLI_POWER=""
NON_INTERACTIVE=false

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==============================================================================
# 1. AUTO-ROOT ESCALATION
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Root privileges required. Requesting sudo...${NC}"
    if command -v sudo &> /dev/null; then
        exec sudo "$0" "$@"
    else
        echo -e "${RED}Error: 'sudo' not found. Please run this script as root.${NC}"
        exit 1
    fi
fi

# ==============================================================================
# 2. ARGUMENT PARSING
# ==============================================================================
usage() {
    echo -e "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --index <ID>      GPU Index (e.g., 0)"
    echo "  --core <MHz>      Core clock offset"
    echo "  --mem <MHz>       Memory clock offset"
    echo "  --power <Watts>   Power limit in WATTS"
    echo "  -y, --yes         Skip confirmation (requires all CLI args)"
    echo "  -h, --help        Show this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --index) CLI_INDEX="$2"; shift 2 ;;
        --core)  CLI_CORE="$2"; shift 2 ;;
        --mem)   CLI_MEM="$2"; shift 2 ;;
        --power) CLI_POWER="$2"; shift 2 ;;
        -y|--yes) NON_INTERACTIVE=true; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
    esac
done

# ==============================================================================
# 3. INSTALLATION OF TEMPLATE SERVICE (ONCE)
# ==============================================================================

TEMPLATE_FILE="/etc/systemd/system/nvidia_oc@.service"

echo -e "${BLUE}Updating systemd template unit at ${TEMPLATE_FILE}...${NC}"

# Note: We use %i in the service file, which represents the instance name (the GPU ID)
# Example: nvidia_oc@0.service -> %i = 0
cat <<EOF > "$TEMPLATE_FILE"
[Unit]
Description=NVIDIA Overclocking Service for GPU %i
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=60
# Load config specific to the GPU index
EnvironmentFile=/etc/conf.d/nvidia_oc_%i

# Enable persistence mode for this specific GPU
ExecStartPre=/usr/bin/nvidia-smi -i %i -pm 1

# Apply settings using the index from the service name (%i)
ExecStart=/usr/bin/nvidia_oc set \\
    --index %i \\
    --power-limit \${NV_POWER_LIMIT} \\
    --freq-offset \${NV_CORE_OFFSET} \\
    --mem-offset \${NV_MEM_OFFSET}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ==============================================================================
# 4. DEPENDENCY CHECK
# ==============================================================================
if ! command -v nvidia_oc &> /dev/null; then
    echo -e "${YELLOW}nvidia_oc binary not found.${NC}"
    REAL_USER="${SUDO_USER:-$USER}"
    if [[ "$REAL_USER" == "root" ]]; then
        echo -e "${RED}Error: Cannot install AUR package as pure root.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Installing 'nvidia_oc' as user '$REAL_USER'...${NC}"
    if command -v yay &> /dev/null; then
        sudo -u "$REAL_USER" yay -S --noconfirm nvidia_oc
    elif command -v paru &> /dev/null; then
        sudo -u "$REAL_USER" paru -S --noconfirm nvidia_oc
    else
        echo -e "${RED}Error: No AUR helper found.${NC}"
        exit 1
    fi
fi

# ==============================================================================
# 5. CONFIGURATION FUNCTION
# ==============================================================================

configure_gpu() {
    local IDX=$1
    local CORE=$2
    local MEM=$3
    local PWR=$4
    local INTERACTIVE=$5

    echo -e "\n${BLUE}=== Configuring GPU Index: $IDX ===${NC}"

    # Show current stats if possible
    if command -v nvidia_oc &> /dev/null; then
        echo -e "${YELLOW}Current State:${NC}"
        nvidia_oc get --index "$IDX" 2>/dev/null || echo "GPU $IDX not accessible via nvidia_oc yet."
    fi

    # Interactive prompts if arguments are missing
    if [ -z "$CORE" ]; then read -p "Enter Core Offset (MHz) [Default: 0]: " CORE; fi
    CORE="${CORE:-0}"

    if [ -z "$MEM" ]; then read -p "Enter Memory Offset (MHz) [Default: 0]: " MEM; fi
    MEM="${MEM:-0}"

    if [ -z "$PWR" ]; then read -p "Enter Power Limit (Watts) [0 to skip]: " PWR; fi
    PWR="${PWR:-0}"

    # Calc mW
    local PWR_MW=$((PWR * 1000))

    # Confirmation
    echo -e "${YELLOW}Settings for GPU $IDX:${NC}"
    echo "  Core:  $CORE MHz"
    echo "  Mem:   $MEM MHz"
    echo "  Power: $PWR W ($PWR_MW mW)"

    if [ "$INTERACTIVE" = true ]; then
        read -p "Apply and enable service? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then return; fi
    fi

    # Write Config File
    local CONF_FILE="/etc/conf.d/nvidia_oc_${IDX}"
    echo -e "${BLUE}Writing config to ${CONF_FILE}...${NC}"
    cat <<EOF > "$CONF_FILE"
# Configuration for nvidia_oc@${IDX}.service
NV_CORE_OFFSET=${CORE}
NV_MEM_OFFSET=${MEM}
NV_POWER_LIMIT=${PWR_MW}
EOF

    # Enable and Restart specific service
    echo -e "${BLUE}Enabling nvidia_oc@${IDX}.service...${NC}"
    systemctl enable "nvidia_oc@${IDX}.service"
    systemctl restart "nvidia_oc@${IDX}.service"

    sleep 1
    if systemctl is-active --quiet "nvidia_oc@${IDX}.service"; then
        echo -e "${GREEN}Success! GPU $IDX configured and running.${NC}"
    else
        echo -e "${RED}Warning: Service failed to start. Check 'systemctl status nvidia_oc@${IDX}'${NC}"
    fi
}

# ==============================================================================
# 6. MAIN LOGIC
# ==============================================================================

# If CLI arguments were provided for a specific index, just run that once
if [ -n "$CLI_INDEX" ]; then
    configure_gpu "$CLI_INDEX" "$CLI_CORE" "$CLI_MEM" "$CLI_POWER" "$(! $NON_INTERACTIVE)"
    exit 0
fi

# Interactive Loop for Multiple GPUs
while true; do
    echo -e "\n${BLUE}--- NVIDIA Multi-GPU Setup ---${NC}"
    echo "Available GPUs:"
    nvidia-smi --query-gpu=index,name,power.draw,power.limit --format=csv,noheader

    read -p "Enter GPU Index to configure (or 'q' to quit): " input
    if [[ "$input" == "q" ]]; then break; fi

    if [[ -z "$input" ]]; then continue; fi

    configure_gpu "$input" "" "" "" true
done

echo -e "${GREEN}All done.${NC}"
