#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and prevent errors in pipelines from being masked.
set -euo pipefail

# Detect the package manager and install irqbalance
if [ -x "$(command -v apt-get)" ]; then
    echo "Debian/Ubuntu detected. Installing irqbalance..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y irqbalance
    CONFIG_FILE="/etc/default/irqbalance"

elif [ -x "$(command -v dnf)" ]; then
    echo "RHEL/CentOS/Fedora (dnf) detected. Installing irqbalance..."
    dnf install -y irqbalance
    CONFIG_FILE="/etc/sysconfig/irqbalance"

elif [ -x "$(command -v yum)" ]; then
    echo "RHEL/CentOS (yum) detected. Installing irqbalance..."
    yum install -y irqbalance
    CONFIG_FILE="/etc/sysconfig/irqbalance"

elif [ -x "$(command -v pacman)" ]; then
    echo "Arch Linux detected. Installing irqbalance..."
    pacman -Sy --noconfirm irqbalance
    CONFIG_FILE="/etc/conf.d/irqbalance"

else
    echo "Error: Supported package manager (apt, dnf, yum, pacman) not found." >&2
    exit 1
fi

# Configure irqbalance
if [ -f "$CONFIG_FILE" ]; then
    echo "Configuring irqbalance at $CONFIG_FILE..."

    # Backup the original config file
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # Set ONESHOT to no
    if grep -q "^#\?IRQBALANCE_ONESHOT" "$CONFIG_FILE"; then
        sed -i 's/^#\?IRQBALANCE_ONESHOT.*/IRQBALANCE_ONESHOT="no"/' "$CONFIG_FILE"
    else
        echo 'IRQBALANCE_ONESHOT="no"' >> "$CONFIG_FILE"
    fi
else
    echo "Configuration file $CONFIG_FILE not found. Creating a default configuration..."
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat <<EOF > "$CONFIG_FILE"
# Configuration for irqbalance
IRQBALANCE_ONESHOT="no"
EOF
fi

# Enable and start the service
echo "Starting and enabling irqbalance service..."
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable irqbalance
    systemctl restart irqbalance
else
    # Fallback for systems running sysvinit or upstart
    if [ -x "$(command -v service)" ]; then
        service irqbalance restart || true
    elif [ -x "$(command -v /etc/init.d/irqbalance)" ]; then
        /etc/init.d/irqbalance restart || true
    fi
fi

echo "irqbalance installation and configuration complete."
