#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./pc-opt.sh)"
  exit 1
fi

echo "🎮 Optimizing PC for Gaming and Daily Usage..."

# 1. Kernel Network Tuning for Low Latency
echo "Applying Kernel Network optimizations..."
cat <<EOF > /etc/sysctl.d/99-gaming-pc.conf
# Use CAKE Qdisc (The absolute best algorithm for keeping ping stable while downloading/streaming)
net.core.default_qdisc = cake

# Use BBR for fast game downloads and daily browsing
net.ipv4.tcp_congestion_control = bbr

# Optimize TCP to not build up unnecessary queues (Lowers latency for daily usage)
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0

# Increase network buffers to prevent dropped packets
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Help with MTU blackholes (Improves reliability over VPNs/Proxies)
net.ipv4.tcp_mtu_probing = 1

# Reduce swappiness (Prevents the game from stuttering when RAM gets full)
vm.swappiness = 10
EOF

# Apply sysctl changes
sysctl --system > /dev/null

# 2. Disable Wi-Fi Power Management
# Linux Wi-Fi power saving often puts the Wi-Fi card to sleep between packets, causing massive ping spikes in games.
if [ -d "/etc/NetworkManager/conf.d" ]; then
    echo "Disabling Wi-Fi Power Saving for NetworkManager..."
    cat <<EOF > /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
[connection]
wifi.powersave = 2
EOF
    systemctl restart NetworkManager
else
    echo "NetworkManager not found, skipping Wi-Fi power save tweak."
fi

# 3. Optimize System RTC frequency (Improves game engine timing/FPS stability)
echo "Improving system timing frequency..."
echo 'dev.hpet.max-user-freq=3072' > /etc/sysctl.d/99-hpet.conf
sysctl -p /etc/sysctl.d/99-hpet.conf > /dev/null

echo "✅ PC Optimization Complete! Stable ping and fast downloads are ready."
