#!/usr/bin/env bash

# Exit on error
set -e

# Colors for output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}=== Logrotate Configuration Setup ===${NC}"

# 1. Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root.${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# 2. Check if logrotate is installed
if ! command -v logrotate &> /dev/null; then
    echo -e "${RED}Error: logrotate is not installed.${NC}"
    exit 1
fi

# 3. Detect OS (Arch vs Debian/Ubuntu)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_LIKE=$ID_LIKE
else
    echo -e "${RED}Cannot detect OS.${NC}"
    exit 1
fi

IS_ARCH=false
IS_DEBIAN=false

if [[ "$OS" == "arch" || "$OS_LIKE" == *"arch"* ]]; then
    IS_ARCH=true
    echo -e "Detected OS: ${GREEN}Arch Linux (or derivative)${NC}"
elif [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
    IS_DEBIAN=true
    echo -e "Detected OS: ${GREEN}Ubuntu/Debian${NC}"
else
    echo -e "${YELLOW}Warning: OS not explicitly recognized as Arch or Debian/Ubuntu. Proceeding with general setup...${NC}"
fi

echo "----------------------------------------"

# 4. Gather user input
read -p "Enter a name for this config (e.g., myapp): " APP_NAME
if [ -z "$APP_NAME" ]; then
    echo -e "${RED}App name cannot be empty.${NC}"
    exit 1
fi

read -p "Enter the log file path (e.g., /var/log/myapp/*.log): " LOG_PATH
if [ -z "$LOG_PATH" ]; then
    echo -e "${RED}Log path cannot be empty.${NC}"
    exit 1
fi

# Handle postrotate script
read -p "Do you need a postrotate command (e.g., to reload Nginx/MySQL)? [y/N]: " NEED_POST
POST_CMD=""
if [[ "$NEED_POST" =~ ^[Yy]$ ]]; then
    read -p "Enter the exact postrotate command: " POST_CMD
fi

# 5. OS-Specific adjustments (Arch rarely uses the 'adm' group, Debian does)
LOG_GROUP="adm"
if ! getent group adm >/dev/null; then
    LOG_GROUP="root" # Fallback if 'adm' group doesn't exist
fi

# 6. Generate configuration file
CONFIG_FILE="/etc/logrotate.d/$APP_NAME"

echo -e "\n${CYAN}Generating $CONFIG_FILE...${NC}"

cat <<EOF > "$CONFIG_FILE"
$LOG_PATH {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root $LOG_GROUP
EOF

# Append postrotate block if requested
if [[ -n "$POST_CMD" ]]; then
    cat <<EOF >> "$CONFIG_FILE"
    sharedscripts
    postrotate
        $POST_CMD
    endscript
EOF
fi

# Close the block
echo "}" >> "$CONFIG_FILE"

echo -e "${GREEN}Successfully created $CONFIG_FILE${NC}"

# 7. OS-Specific Service enabling
echo "----------------------------------------"
if $IS_ARCH; then
    echo -e "${CYAN}Arch Linux requires a systemd timer for logrotate.${NC}"
    echo "Enabling and starting logrotate.timer..."
    systemctl enable --now logrotate.timer
    echo -e "${GREEN}Timer enabled! Check status with: systemctl status logrotate.timer${NC}"
elif $IS_DEBIAN; then
    echo -e "${CYAN}Ubuntu/Debian detected.${NC}"
    echo -e "Logrotate is automatically triggered daily via cron (${YELLOW}/etc/cron.daily/logrotate${NC}). No extra services need to be enabled."
fi

# 8. Testing instructions
echo "----------------------------------------"
echo -e "${YELLOW}=== CRUCIAL STEP: Testing ===${NC}"
echo "Your configuration has been created. It is highly recommended to test it now."
echo ""
echo -e "To perform a ${GREEN}Dry Run${NC} (verifies syntax without moving files):"
echo -e "  sudo logrotate -d $CONFIG_FILE"
echo ""
echo -e "To ${RED}Force Run${NC} (execute rotation immediately):"
echo -e "  sudo logrotate -f $CONFIG_FILE"
echo ""
echo -e "Setup complete! 🎉"
