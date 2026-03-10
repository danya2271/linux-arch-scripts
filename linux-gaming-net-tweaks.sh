#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./pc-max.sh)"
  exit 1
fi

echo "🔥 Applying ABSOLUTE MAXIMUM Optimizations for Gaming & Daily Usage..."

# ==========================================
# 1. KERNEL NETWORK TUNING (Sysctl)
# ==========================================
echo "Applying Extreme Kernel Network optimizations..."
cat <<EOF > /etc/sysctl.d/99-gaming-pc-max.conf
# Queueing & Congestion (Anti-Bufferbloat & Speed)
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

# TCP Latency & Queue Management
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# Maximum Network Buffers (Prevents packet drops under load)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Extreme Connection Backlog limits (Handles burst traffic instantly)
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# System latency tweaks
vm.swappiness = 10
dev.hpet.max-user-freq = 3072
EOF

sysctl --system > /dev/null

# ==========================================
# 2. WI-FI POWER MANAGEMENT
# ==========================================
if [ -d "/etc/NetworkManager/conf.d" ]; then
    echo "Disabling Wi-Fi Power Saving..."
    cat <<EOF > /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
[connection]
wifi.powersave = 2
EOF
    systemctl restart NetworkManager
fi

# ==========================================
# 3. PCIE ASPM (Hardware Power Saving)
# ==========================================
echo "Disabling PCIe ASPM in GRUB (Requires Reboot)..."
if [ -f /etc/default/grub ]; then
    if ! grep -q "pcie_aspm=off" /etc/default/grub; then
        # Append pcie_aspm=off to GRUB_CMDLINE_LINUX_DEFAULT
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=off /' /etc/default/grub

        # Detect distro and update GRUB accordingly
        if command -v update-grub >/dev/null 2>&1; then
            update-grub > /dev/null
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg > /dev/null
        elif command -v grub2-mkconfig >/dev/null 2>&1; then
            grub2-mkconfig -o /boot/grub2/grub.cfg > /dev/null
        fi
        echo "GRUB updated."
    else
        echo "PCIe ASPM is already disabled in GRUB."
    fi
else
    echo "GRUB configuration not found, skipping PCIe tweak."
fi

# ==========================================
# 4. HARDWARE NIC TUNING (ethtool)
# ==========================================
echo "Configuring hardware-level NIC tuning (Interrupt Coalescing & Flow Control)..."

# Ensure ethtool is installed
if ! command -v ethtool >/dev/null 2>&1; then
    echo "Warning: 'ethtool' is not installed. Installing it now..."
    if command -v apt >/dev/null; then apt install ethtool -y > /dev/null
    elif command -v pacman >/dev/null; then pacman -S ethtool --noconfirm > /dev/null
    elif command -v dnf >/dev/null; then dnf install ethtool -y > /dev/null
    fi
fi

# Create a helper script to apply ethtool settings to all Ethernet interfaces
cat <<'EOF' > /usr/local/bin/extreme-nic-tune.sh
#!/bin/bash
# Find all physical ethernet interfaces (usually start with 'en' or 'eth')
for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^en|^eth'); do
    # Force instant CPU wake-up for packets (0 microsecond delay)
    ethtool -C "$IFACE" rx-usecs 0 tx-usecs 0 2>/dev/null
    # Disable Ethernet Pause Frames (Ignores router congestion signals)
    ethtool -A "$IFACE" rx off tx off 2>/dev/null
done
exit 0
EOF

chmod +x /usr/local/bin/extreme-nic-tune.sh

# Create a systemd service to run the ethtool script automatically on every boot
cat <<EOF > /etc/systemd/system/extreme-nic-tune.service
[Unit]
Description=Extreme NIC Tuning (Interrupt Coalescing & Flow Control)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/extreme-nic-tune.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now extreme-nic-tune.service > /dev/null 2>&1

echo "=========================================="
echo "✅ MAXIMUM Optimizations Applied Successfully!"
echo "⚠️ IMPORTANT: You MUST REBOOT your computer for the PCIe hardware tweaks to apply."
echo "=========================================="
