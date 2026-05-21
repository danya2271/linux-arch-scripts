#!/bin/bash

# ==============================================================================
# Arch Linux Laptop Battery Optimization Script v2.0 (Self-Elevating & Undervolting)
# ==============================================================================
# This script automates the application of the most effective power-saving
# tweaks for laptops running Arch Linux.
#
# What it does:
# 1. Automatically requests sudo privileges if not run as root.
# 2. Installs and configures TLP and Powertop for core power management.
# 3. Detects your bootloader and adds power-saving kernel parameters.
# 4. **NEW**: Offers an interactive setup for CPU undervolting for supported
#    Intel CPUs and provides guidance for AMD CPUs.
# 5. Provides advice on other manual tweaks for maximum battery life.
#
# DISCLAIMER: Undervolting can lead to system instability if set too
# aggressively. This script is provided as-is. Always back up important files.
# ==============================================================================

# --- Elevate privileges to root if not already ---
if [[ "$EUID" -ne 0 ]]; then
  echo "This script requires root privileges to install packages and modify system files."
  echo "Attempting to re-launch with sudo..."
  sudo bash "$0" "$@"
  exit $?
fi

# --- Color Codes for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---
function print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# --- Undervolting Logic ---
function configure_undervolt() {
    echo
    print_info "--- Advanced: CPU Undervolting ---"
    print_warn "Undervolting can significantly reduce power consumption and heat, but"
    print_warn "setting values too aggressively will cause system freezes and crashes."
    print_warn "Proceed with caution. It is recommended to start with small values."
    echo

    read -p "Do you want to attempt to configure CPU undervolting? (y/N): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        print_info "Skipping undervolting setup."
        return
    fi

    # --- INTEL CPU LOGIC ---
    if lscpu | grep -q "GenuineIntel"; then
        print_info "Intel CPU detected. We will use 'intel-undervolt'."
        pacman -S --noconfirm --needed intel-undervolt

        print_info "Please provide the undervolt offset values in millivolts (mV)."
        print_info "A safe starting point is usually between -50 and -80 for CPU/Cache."

        local uv_cpu=0
        local uv_gpu=0

        read -p "Enter CPU Core & Cache undervolt value (e.g., -80): " uv_cpu
        read -p "Enter integrated GPU undervolt value (e.g., -40): " uv_gpu

        # Basic validation
        if ! [[ "$uv_cpu" =~ ^-?[0-9]+$ ]] || ! [[ "$uv_gpu" =~ ^-?[0-9]+$ ]]; then
            print_error "Invalid input. Please enter integer numbers. Aborting undervolt setup."
            return
        fi

        print_info "Creating config file at /etc/intel-undervolt.conf..."
        cat << EOF > /etc/intel-undervolt.conf
//
// /etc/intel-undervolt.conf
//
// Lines beginning with // are comments.
// All values are in millivolts (mV).
//

undervolt 0 'CPU' $uv_cpu
undervolt 1 'GPU' $uv_gpu
undervolt 2 'CPU Cache' $uv_cpu
undervolt 3 'System Agent' 0
undervolt 4 'Analog I/O' 0
EOF

        systemctl enable --now intel-undervolt.service
        print_info "Intel undervolt service has been enabled and started."
        print_warn "To test stability, run a CPU stress test. If your system freezes,"
        print_warn "reboot and edit '/etc/intel-undervolt.conf' with less aggressive values."

    # --- AMD CPU LOGIC ---
    elif lscpu | grep -q "AuthenticAMD"; then
        print_info "AMD CPU detected. Automatic configuration is not recommended."
        print_info "AMD Ryzen undervolting/power management is best handled by tools from the AUR."
        echo
        print_info "Recommended tool: 'ryzenadj' (command-line)."
        print_info "Recommended GUI front-ends for ryzenadj: 'ryzen-controller' or 'tuxedo-control-center'."
        echo
        print_warn "Please research the best settings for your specific CPU model on the Arch Wiki"
        print_warn "or other forums before applying any changes with these tools."
    else
        print_error "Could not determine CPU type for undervolting."
    fi
}


# --- Main Logic ---

# 1. Welcome and User Confirmation
clear
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN} Arch Linux Laptop Battery Optimization Script ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo
print_info "This script will perform the following actions:"
echo " 1. Install and configure TLP and Powertop."
echo " 2. Add power-saving kernel parameters to your bootloader."
echo " 3. Optionally, guide you through setting up CPU undervolting."
echo
read -p "Do you want to proceed? (y/N): " choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# 2. Install Core Packages
print_info "Updating package database and installing TLP and Powertop..."
pacman -Sy --noconfirm --needed tlp tlp-rdw powertop
if [ $? -ne 0 ]; then
    print_error "Failed to install packages. Exiting."
    exit 1
fi

# 3. Configure TLP
print_info "Configuring TLP..."
systemctl enable --now tlp.service
systemctl mask systemd-rfkill.service systemd-rfkill.socket &> /dev/null

# 4. Make Powertop Tunables Persistent
print_info "Creating systemd service for Powertop..."
cat << EOF > /etc/systemd/system/powertop.service
[Unit]
Description=Powertop tunings
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/powertop --auto-tune
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now powertop.service

# 5. Apply Kernel Parameters
print_info "Applying power-saving kernel parameters..."
KERNEL_PARAMS="pcie_aspm=force nvme_core.default_ps_max_latency_us=5500"
if lscpu | grep -q "AuthenticAMD"; then
    KERNEL_PARAMS="$KERNEL_PARAMS amd_pstate=passive"
elif lscpu | grep -q "GenuineIntel"; then
    KERNEL_PARAMS="$KERNEL_PARAMS i915.enable_fbc=1"
fi

BOOTLOADER=""
if [ -f "/boot/grub/grub.cfg" ]; then
    BOOTLOADER="GRUB"
elif [ -d "/boot/loader" ] && [ -f "/boot/loader/loader.conf" ]; then
    BOOTLOADER="systemd-boot"
fi

case $BOOTLOADER in
    "GRUB")
        print_info "GRUB bootloader detected."
        GRUB_CONFIG="/etc/default/grub"
        print_warn "Backing up $GRUB_CONFIG to $GRUB_CONFIG.bak"
        cp "$GRUB_CONFIG" "$GRUB_CONFIG.bak"
        CURRENT_PARAMS=$(grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_CONFIG" | cut -d'"' -f2)
        NEW_PARAMS=$CURRENT_PARAMS
        for param in $KERNEL_PARAMS; do
            if ! [[ "$CURRENT_PARAMS" =~ "$param" ]]; then NEW_PARAMS="$NEW_PARAMS $param"; fi
        done
        sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"\).*\(\"\)/\1$NEW_PARAMS\2/" "$GRUB_CONFIG"
        grub-mkconfig -o /boot/grub/grub.cfg
        print_info "GRUB configuration updated."
        ;;
    "systemd-boot")
        print_info "systemd-boot detected."
        CONF_FILE=$(find /boot/loader/entries/ -name "*.conf" -type f -exec grep -l "$(uname -r)" {} + | head -n 1)
        if [ -z "$CONF_FILE" ]; then
            print_error "Could not find a systemd-boot entry for the current kernel."
            print_warn "Please add manually: $KERNEL_PARAMS"
        else
            print_info "Found entry file: $CONF_FILE"
            print_warn "Backing up $CONF_FILE to $CONF_FILE.bak"
            cp "$CONF_FILE" "$CONF_FILE.bak"
            CURRENT_OPTS=$(grep "^options" "$CONF_FILE")
            NEW_OPTS=$CURRENT_OPTS
            for param in $KERNEL_PARAMS; do
                if ! [[ "$CURRENT_OPTS" =~ "$param" ]]; then NEW_OPTS="$NEW_OPTS $param"; fi
            done
            sed -i "s|^options.*|${NEW_OPTS}|" "$CONF_FILE"
            print_info "Successfully added kernel parameters to $CONF_FILE."
        fi
        ;;
    *)
        print_error "Could not detect GRUB or systemd-boot."
        print_warn "Please add these kernel parameters manually: $KERNEL_PARAMS"
        ;;
esac

# 6. Configure Undervolting (New Step)
configure_undervolt

# 7. Final Recommendations
echo
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}       🚀 Optimization Complete! 🚀          ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo
print_info "The core power-saving tweaks have been applied."
print_warn "A ${YELLOW}reboot is required${NC} for all changes to take full effect."
echo
echo -e "${YELLOW}--- Additional Manual Tweaks for Even Better Battery Life ---${NC}"
echo -e "  💻 ${GREEN}Screen Refresh Rate:${NC} Lowering your screen's refresh rate on battery is a huge power saver."
echo -e "  🎮 ${GREEN}NVIDIA GPUs:${NC} Use 'envycontrol' or 'supergfxctl' (from the AUR) to switch to integrated graphics."
echo -e "  💡 ${GREEN}Final Check:${NC} After rebooting, run 'sudo tlp-stat -s' and 'sudo powertop'."
echo
read -p "Press Enter to finish."
