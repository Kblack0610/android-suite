#!/usr/bin/env bash
# Android Provisioning Suite - Base Functions
# Shared utilities, logging, and ADB helpers

set -euo pipefail

# Get script directory for relative sourcing
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_section() {
    echo "" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${BLUE}  $*${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $*" >&2
    fi
}

# =============================================================================
# ADB Helpers
# =============================================================================

# Check if ADB is available
check_adb() {
    if ! command -v adb &>/dev/null; then
        log_error "ADB not found. Please install Android SDK Platform Tools."
        log_info "  Arch: sudo pacman -S android-tools"
        log_info "  Debian: sudo apt install adb"
        log_info "  macOS: brew install android-platform-tools"
        return 1
    fi
    return 0
}

# Check if a device is connected and authorized
check_device() {
    if ! check_adb; then
        return 1
    fi

    local devices
    devices=$(adb devices 2>/dev/null | grep -v "List" | grep -v "^$")

    if [[ -z "$devices" ]]; then
        log_error "No Android device connected"
        log_info "Connect a device via USB and enable USB debugging"
        return 1
    fi

    if echo "$devices" | grep -q "unauthorized"; then
        log_error "Device connected but not authorized"
        log_info "Check your phone and accept the RSA fingerprint prompt"
        return 1
    fi

    if echo "$devices" | grep -q "offline"; then
        log_error "Device is offline. Try reconnecting."
        return 1
    fi

    return 0
}

# Wait for device with timeout
wait_for_device() {
    local timeout="${1:-30}"
    log_info "Waiting for device (${timeout}s timeout)..."

    if timeout "$timeout" adb wait-for-device 2>/dev/null; then
        log_success "Device connected"
        return 0
    else
        log_error "Timeout waiting for device"
        return 1
    fi
}

# Get friendly short name for a device model string
# Strips Samsung SM_ prefix, lowercases, maps known codenames
device_short_name() {
    local model="${1:-unknown}"
    local short
    short=$(echo "$model" | sed 's/SM[-_]//I' | tr '[:upper:]' '[:lower:]' | tr -d '\r')
    # Map known model numbers to friendly names
    case "$short" in
        *f946*|*f956*) short="zfold6" ;;
        *f936*|*f926*) short="zfold5" ;;
        *f731*|*f721*) short="zflip5" ;;
        *f741*|*f711*) short="zflip6" ;;
        *s938*|*s928*) short="s25ultra" ;;
        *s936*|*s926*) short="s25+" ;;
        *s931*|*s921*) short="s25" ;;
        *s918*)        short="s23ultra" ;;
        *s916*)        short="s23+" ;;
        *s911*)        short="s23" ;;
        *s908*)        short="s22ultra" ;;
        *s906*|*s901*) short="s22" ;;
        *g998*)        short="s21ultra" ;;
        *g996*)        short="s21+" ;;
        *g991*)        short="s21" ;;
        *a556*|*a546*) short="a55" ;;
        *a356*|*a346*) short="a35" ;;
        *a256*|*a246*) short="a25" ;;
        *a156*|*a146*) short="a15" ;;
        # Lenovo Tab M-series (wall-panel kiosks) — verify codes with getprop ro.product.model
        *tb330*|*tb331*|*tb350*) short="m11" ;;   # Tab M11 (TB330FU/TB331FC...)
        *tb310*|*tb312*)         short="m9"  ;;   # Tab M9  (TB310FU/TB310XU...)
    esac
    echo "$short"
}

# List connected devices with friendly names
# Output format: short_name  serial  full_model
list_devices() {
    local format="${1:-table}"  # table or plain
    local devices_found=0

    while read -r serial _ rest; do
        [[ -z "$serial" ]] && continue
        local model
        model=$(echo "$rest" | grep -oP 'model:\K[^ ]+' || echo "unknown")
        local short
        short=$(device_short_name "$model")
        if [[ "$format" == "table" ]]; then
            printf "  ${CYAN}%-14s${NC} %-20s %s\n" "$short" "$serial" "$model" >&2
        else
            printf "  %s  %s  (%s)\n" "$serial" "$short" "$model" >&2
        fi
        ((devices_found++)) || true
    done < <(adb devices -l 2>/dev/null | grep -w device)

    if [[ "$devices_found" -eq 0 ]]; then
        log_error "No devices connected"
        return 1
    fi
    return 0
}

# Get single device serial (or prompt if multiple)
get_device_serial() {
    # If DEVICE_SERIAL already set (via --serial flag), verify and use it
    if [[ -n "${DEVICE_SERIAL:-}" ]]; then
        local devices
        devices=$(adb devices 2>/dev/null | grep -E "device$" | awk '{print $1}')
        if echo "$devices" | grep -q "^${DEVICE_SERIAL}$"; then
            echo "$DEVICE_SERIAL"
            return 0
        else
            log_error "Specified device not found: $DEVICE_SERIAL"
            log_info "Available devices:"
            echo "$devices" | sed 's/^/  /'
            return 1
        fi
    fi

    local devices
    devices=$(adb devices 2>/dev/null | grep -E "device$" | awk '{print $1}')
    local count
    count=$(echo "$devices" | grep -c . || true)

    if [[ "$count" -eq 0 ]]; then
        log_error "No authorized device found"
        return 1
    elif [[ "$count" -eq 1 ]]; then
        echo "$devices"
    else
        # Multiple devices - require explicit --serial flag
        log_error "Multiple devices connected. Specify one with --serial:" >&2
        echo "" >&2
        list_devices table
        echo "" >&2
        log_info "Example: provision.sh --serial $(echo "$devices" | head -1) apps --set minimal" >&2
        return 1
    fi
}

# Run ADB command with device serial
adb_cmd() {
    local serial="${DEVICE_SERIAL:-}"
    if [[ -n "$serial" ]]; then
        adb -s "$serial" "$@"
    else
        adb "$@"
    fi
}

# =============================================================================
# Settings Helpers
# =============================================================================

# Put a system setting
setting_put() {
    local namespace="$1"  # system, secure, or global
    local key="$2"
    local value="$3"

    log_debug "Setting $namespace/$key = $value"
    adb_cmd shell settings put "$namespace" "$key" "$value"
}

# Get a system setting
setting_get() {
    local namespace="$1"
    local key="$2"

    adb_cmd shell settings get "$namespace" "$key"
}

# =============================================================================
# Package Management
# =============================================================================

# Uninstall a package (user-level, preserves data)
uninstall_package() {
    local package="$1"
    local keep_data="${2:-true}"

    if [[ "$keep_data" == "true" ]]; then
        adb_cmd shell pm uninstall -k --user 0 "$package" 2>/dev/null || true
    else
        adb_cmd shell pm uninstall --user 0 "$package" 2>/dev/null || true
    fi
}

# Check if package is installed
is_package_installed() {
    local package="$1"
    adb_cmd shell pm list packages 2>/dev/null | grep -q "^package:${package}$"
}

# Install an APK
install_apk() {
    local apk_path="$1"
    local apk_name
    apk_name=$(basename "$apk_path")

    if [[ ! -f "$apk_path" ]]; then
        log_error "APK not found: $apk_path"
        return 1
    fi

    log_info "Installing $apk_name..."
    local output
    output=$(adb_cmd install -r "$apk_path" 2>&1)
    local result=$?

    if [[ $result -eq 0 ]]; then
        log_success "Installed $apk_name"
        return 0
    fi

    # Check for signature mismatch - need to uninstall first
    if echo "$output" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
        log_warning "Signature mismatch - attempting uninstall and reinstall"

        # Try to get package name from aapt if available
        local package_name=""
        if command -v aapt &>/dev/null; then
            package_name=$(aapt dump badging "$apk_path" 2>/dev/null | grep "^package:" | sed "s/.*name='\\([^']*\\)'.*/\\1/")
        fi

        # Fallback: extract from APK filename (common pattern: package.name_version.apk)
        if [[ -z "$package_name" ]]; then
            package_name="${apk_name%_*}"  # Remove _version.apk
            package_name="${package_name%.apk}"  # Remove .apk if no version
        fi

        if [[ -n "$package_name" ]]; then
            log_info "Uninstalling existing: $package_name"
            adb_cmd shell pm uninstall "$package_name" &>/dev/null || true

            # Retry install
            if adb_cmd install "$apk_path" 2>/dev/null; then
                log_success "Installed $apk_name (after uninstall)"
                return 0
            fi
        fi
    fi

    log_error "Failed to install $apk_name"
    log_debug "Install output: $output"
    return 1
}

# =============================================================================
# Profile Helpers
# =============================================================================

# Load a profile configuration
load_profile() {
    local profile_name="$1"
    local profile_path="$SUITE_DIR/profiles/${profile_name}.conf"

    if [[ ! -f "$profile_path" ]]; then
        log_error "Profile not found: $profile_name"
        return 1
    fi

    log_info "Loading profile: $profile_name"
    # shellcheck disable=SC1090
    source "$profile_path"
}

# =============================================================================
# Utility Functions
# =============================================================================

# Check if running in dry-run mode
is_dry_run() {
    [[ "${DRY_RUN:-0}" == "1" ]]
}

# Confirm action (skip in non-interactive mode)
confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "${FORCE:-0}" == "1" ]]; then
        return 0
    fi

    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " yn
        yn="${yn:-y}"
    else
        read -rp "$prompt [y/N]: " yn
        yn="${yn:-n}"
    fi

    [[ "${yn,,}" == "y" ]]
}

# =============================================================================
# Wireless ADB Helpers
# =============================================================================

# Get device IP address
get_device_ip() {
    local ip
    # Try multiple methods to get IP
    ip=$(adb_cmd shell ip route 2>/dev/null | awk '/wlan0/ {print $9}' | head -1)

    if [[ -z "$ip" ]]; then
        # Fallback: try ip addr
        ip=$(adb_cmd shell ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    fi

    if [[ -z "$ip" ]]; then
        # Fallback: ifconfig
        ip=$(adb_cmd shell ifconfig wlan0 2>/dev/null | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')
    fi

    echo "$ip"
}

# Connect to a device over the network (TCP/IP)
# Args: host[:port]  (port defaults to 5555)
adb_connect() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        log_error "adb_connect: host[:port] required"
        return 1
    fi

    # Default the port if only a bare host/IP was given
    [[ "$target" == *:* ]] || target="${target}:5555"

    if is_dry_run; then
        log_info "[DRY-RUN] Would run: adb connect $target"
        echo "$target"
        return 0
    fi

    log_info "Connecting to $target ..."
    local out
    out=$(adb connect "$target" 2>&1)

    # adb connect prints "connected to ..." or "already connected to ..." on success
    if echo "$out" | grep -qiE "connected to"; then
        log_success "Connected: $target"
        echo "$target"
        return 0
    fi

    log_error "Failed to connect to $target"
    log_debug "adb connect output: $out"
    return 1
}

# Pair with a device using Android 11+ Wireless debugging
# Args: host:pairPort  code
# Note: the pairing port/code come from Settings > Developer options > Wireless
#       debugging > "Pair device with pairing code" and differ from the connect port.
adb_pair() {
    local pair_target="${1:-}"
    local code="${2:-}"

    if [[ -z "$pair_target" || -z "$code" ]]; then
        log_error "adb_pair: <host:pairPort> <code> required"
        return 1
    fi

    # adb pair needs platform-tools >= 30. Note: `adb version` line 1 is the protocol
    # ("version 1.0.41"); the platform-tools version is the later "Version 35.x" line —
    # take the LAST version token so we don't read the protocol's "1".
    local adb_major
    adb_major=$(adb version 2>/dev/null | grep -iE 'version [0-9]+\.[0-9]+' \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1 | cut -d. -f1)
    if [[ -n "$adb_major" && "$adb_major" -lt 30 ]]; then
        log_error "'adb pair' requires platform-tools >= 30 (found version $adb_major)"
        log_info "Update: Arch 'sudo pacman -S android-tools', or use --from-usb / tcpip instead"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would run: adb pair $pair_target <code>"
        return 0
    fi

    log_info "Pairing with $pair_target ..."
    local out
    out=$(adb pair "$pair_target" "$code" 2>&1)

    if echo "$out" | grep -qiE "successfully paired"; then
        log_success "Paired with $pair_target"
        return 0
    fi

    log_error "Pairing failed for $pair_target"
    log_info "Re-check the ip:port and 6-digit code on the tablet (they rotate each time)"
    log_debug "adb pair output: $out"
    return 1
}

# Enable wireless ADB (TCP/IP mode)
enable_wireless_adb() {
    local port="${1:-5555}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would enable wireless ADB on port $port"
        return 0
    fi

    log_info "Enabling wireless ADB on port $port..."

    # Enable TCP/IP mode
    if ! adb_cmd tcpip "$port" 2>/dev/null; then
        log_error "Failed to enable TCP/IP mode"
        return 1
    fi

    sleep 2  # Give adbd time to restart

    local ip
    ip=$(get_device_ip)

    if [[ -z "$ip" ]]; then
        log_warning "Could not determine device IP"
        log_info "Find IP in Settings > About Phone > Status"
        log_info "Then connect with: adb connect <ip>:$port"
        return 1
    fi

    log_success "Wireless ADB enabled"

    # Actually connect (not just print) so a one-cable bootstrap ends fully wireless.
    if adb_connect "$ip:$port" >/dev/null; then
        log_info "You can now unplug USB. Network serial: $ip:$port"
    else
        log_warning "tcpip enabled but auto-connect failed"
        log_info "  Connect manually with: adb connect $ip:$port"
    fi

    echo "$ip:$port"
}

# Enable persistent wireless ADB (requires root)
enable_persistent_wireless_adb() {
    local port="${1:-5555}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would enable persistent wireless ADB"
        return 0
    fi

    # Check if rooted
    if ! adb_cmd shell "su -c 'id'" 2>/dev/null | grep -q "uid=0"; then
        log_warning "Persistent wireless ADB requires root"
        log_info "Using non-persistent mode instead"
        enable_wireless_adb "$port"
        return $?
    fi

    log_info "Enabling persistent wireless ADB on port $port..."

    adb_cmd shell su -c "setprop service.adb.tcp.port $port" 2>/dev/null
    adb_cmd shell su -c "stop adbd && start adbd" 2>/dev/null

    sleep 2

    local ip
    ip=$(get_device_ip)

    if [[ -n "$ip" ]]; then
        log_success "Persistent wireless ADB enabled"
        log_info ""
        log_info "  Connect with: adb connect $ip:$port"
        log_info "  This will persist across reboots"
        log_info ""
        echo "$ip:$port"
    else
        log_warning "Wireless ADB enabled but could not determine IP"
    fi
}

# Export functions for use in other scripts
export -f log_info log_error log_warning log_section log_success log_debug
export -f check_adb check_device wait_for_device get_device_serial adb_cmd
export -f setting_put setting_get
export -f uninstall_package is_package_installed install_apk
export -f load_profile is_dry_run confirm
export -f get_device_ip enable_wireless_adb enable_persistent_wireless_adb
export -f adb_connect adb_pair
