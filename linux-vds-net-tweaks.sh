#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./vds-opt.sh)"
  exit 1
fi

echo "🚀 Optimizing VDS for Xray/VLESS..."

# 1. System Limits (Allow high number of concurrent proxy connections)
echo "Configuring file descriptors and limits..."
cat <<EOF > /etc/security/limits.d/99-xray-limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

# Ensure systemd allows high limits for services (like Xray)
sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf

# 2. Kernel Network Tuning for Proxy Servers
echo "Applying TCP and Network optimizations..."
cat <<EOF > /etc/sysctl.d/99-xray-vds.conf
# Use BBR + FQ for maximum throughput on high-latency international links
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Increase max open sockets
fs.file-max = 1048576

# Buffer sizes for high-speed proxying
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Reduce TIME_WAIT sockets to prevent port exhaustion
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Enable TCP Fast Open (Reduces latency on re-connections)
net.ipv4.tcp_fastopen = 3

# Expand ephemeral ports (More simultaneous clients)
net.ipv4.ip_local_port_range = 1024 65535

# Keepalive tweaks (Cleans up dead Xray connections faster)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

# Apply sysctl changes
sysctl --system > /dev/null

# Reload systemd daemon for limit changes
systemctl daemon-reload

echo "✅ VDS Optimization Complete! Please restart your Xray service (e.g., systemctl restart xray)."
