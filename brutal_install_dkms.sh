#!/usr/bin/env bash
#
# tcp-brutal dkms headless installation script
# Designed for automated, non-interactive execution (no TTY required).
#

set -e

export DEBIAN_FRONTEND=noninteractive

### Configuration
DKMS_MODULE_NAME="tcp-brutal"
KERNEL_MODULE_NAME="brutal"
REPO_URL="https://github.com/apernet/tcp-brutal"
HY2_API_BASE_URL="https://api.hy2.io/v1"
INSTALL_LOCK_FILE="${TCP_BRUTAL_INSTALL_LOCK_FILE:-/run/lock/tcp-brutal-install.lock}"
INSTALL_LOCK_TIMEOUT="${TCP_BRUTAL_INSTALL_LOCK_TIMEOUT:-300}"
CURL_FLAGS=(
    --silent
    --show-error
    --fail
    --location
    --connect-timeout 15
    --max-time 300
    --retry 5
    --retry-delay 2
)

INSTALL_LOCK_FD=""
TMP_TARBALL=""
EXTRACT_DIR=""

### Logger
# FIXED: Redirect all logs to stderr (>&2) so they don't pollute variable capturing
log() { echo -e "[INFO] $1" >&2; }
warn() { echo -e "[WARNING] $1" >&2; }
err() { echo -e "[ERROR] $1" >&2; exit 1; }

### Check Root
if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root. Please run with sudo or as the root user."
fi

### Cleanup
cleanup() {
    local exit_status=$?

    [[ -z "$EXTRACT_DIR" ]] || rm -rf -- "$EXTRACT_DIR" || true
    [[ -z "$TMP_TARBALL" ]] || rm -f -- "$TMP_TARBALL" || true

    if [[ -n "$INSTALL_LOCK_FD" ]]; then
        flock --unlock "$INSTALL_LOCK_FD" 2>/dev/null || true
        exec {INSTALL_LOCK_FD}>&-
    fi

    return "$exit_status"
}

trap cleanup EXIT

### Locking
acquire_install_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        err "The 'flock' command is required to safely run this installer."
    fi

    if [[ ! "$INSTALL_LOCK_TIMEOUT" =~ ^[0-9]+$ ]]; then
        err "TCP_BRUTAL_INSTALL_LOCK_TIMEOUT must be a non-negative integer."
    fi

    if ! exec {INSTALL_LOCK_FD}>>"$INSTALL_LOCK_FILE"; then
        err "Failed to open installer lock file ${INSTALL_LOCK_FILE}."
    fi

    log "Acquiring the tcp-brutal installer lock..."
    if ! flock --exclusive --wait "$INSTALL_LOCK_TIMEOUT" "$INSTALL_LOCK_FD"; then
        err "Another tcp-brutal installation is still running (waited ${INSTALL_LOCK_TIMEOUT}s)."
    fi
}

### OS & Dependency Check
install_dependencies() {
    log "Detecting package manager and installing dependencies..."

    local kernel_ver
    kernel_ver="$(uname -r)"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -yq
        apt-get install -yq --no-install-recommends curl grep dkms "linux-headers-${kernel_ver}"

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl grep dkms "kernel-devel-${kernel_ver}"

    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl grep dkms "kernel-devel-${kernel_ver}"

    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y curl grep dkms "kernel-default-devel"

    elif command -v pacman >/dev/null 2>&1; then
        local kernel_img="/lib/modules/${kernel_ver}/vmlinuz"
        if [[ ! -f "$kernel_img" ]]; then
            err "Kernel image not found. If you recently upgraded via pacman, please reboot first."
        fi
        local kernel_pkg
        kernel_pkg=$(pacman -Qoq "$kernel_img")
        pacman -Sy --noconfirm curl grep dkms "${kernel_pkg}-headers"
    else
        err "Unsupported OS or package manager. Cannot install dependencies automatically."
    fi
}

### Version Fetching
get_latest_version() {
    log "Fetching the latest version of tcp-brutal..."
    local api_url="${HY2_API_BASE_URL}/update?cver=installscript&arch=generic&plat=linux&chan=tcp-brutal"

    local version
    version=$(curl "${CURL_FLAGS[@]}" "$api_url" | grep -oP '"lver":\s*\K"v.*?"' | head -1 | tr -d '"')

    if [[ -z "$version" ]]; then
        err "Failed to get the latest version from API. Check your network."
    fi
    # Only this pure data string goes to stdout
    echo "$version"
}

### Download and Install
install_dkms_module() {
    local version="$1"
    local tarball_url="${REPO_URL}/releases/download/${version}/tcp-brutal.dkms.tar.gz"
    TMP_TARBALL=$(mktemp --suffix=".tar.gz")

    log "Downloading version ${version} from ${tarball_url}..."
    curl "${CURL_FLAGS[@]}" "$tarball_url" -o "$TMP_TARBALL"

    log "Cleaning up old DKMS installations of ${DKMS_MODULE_NAME}..."
    if dkms status -m "$DKMS_MODULE_NAME" | grep -q "$DKMS_MODULE_NAME"; then
        dkms remove -m "$DKMS_MODULE_NAME" --all >/dev/null 2>&1 || true
    fi

    log "Extracting and registering DKMS module..."
    EXTRACT_DIR=$(mktemp -d)
    tar xf "$TMP_TARBALL" -C "$EXTRACT_DIR"

    # Read variables from dkms.conf (PACKAGE_NAME, PACKAGE_VERSION)
    # shellcheck source=/dev/null
    source "${EXTRACT_DIR}/dkms_source_tree/dkms.conf"

    if [[ -z "$PACKAGE_NAME" || -z "$PACKAGE_VERSION" ]]; then
        err "Malformed DKMS tarball."
    fi

    local src_dir="/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    cp -a "${EXTRACT_DIR}/dkms_source_tree/." "$src_dir/"
    rm -rf "$EXTRACT_DIR"
    EXTRACT_DIR=""
    rm -f "$TMP_TARBALL"
    TMP_TARBALL=""

    log "Building and installing via DKMS..."
    dkms add "$PACKAGE_NAME/$PACKAGE_VERSION"
    dkms autoinstall
}

### Kernel Module Loading
load_kernel_module() {
    log "Setting up kernel module auto-load..."
    echo "$KERNEL_MODULE_NAME" > "/etc/modules-load.d/${KERNEL_MODULE_NAME}.conf"

    if lsmod | grep -q "^\b${KERNEL_MODULE_NAME}\b"; then
        log "Module is already loaded. Attempting to reload..."
        rmmod "$KERNEL_MODULE_NAME" || warn "Could not unload existing module. A reboot might be required to use the new version."
    fi

    log "Loading module ${KERNEL_MODULE_NAME}..."
    if modprobe "$KERNEL_MODULE_NAME"; then
        log "Successfully loaded ${KERNEL_MODULE_NAME}."
    else
        err "Failed to load ${KERNEL_MODULE_NAME}. Check 'dmesg' or DKMS build logs."
    fi
}

### Main Execution
main() {
    acquire_install_lock
    install_dependencies

    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        warn "Kernel headers might be missing for $(uname -r). DKMS compilation may fail."
    fi

    local latest_version
    latest_version=$(get_latest_version)

    install_dkms_module "$latest_version"
    load_kernel_module

    log "tcp-brutal ${latest_version} has been successfully installed and loaded."
}

main
