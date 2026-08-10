#!/usr/bin/env bash
# Android Provisioning Suite - Main Orchestrator
# Independent dimensions: apps, debloat, config

set -euo pipefail

SUITE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SUITE_DIR/base_functions.sh"

VERSION="2.0.0"

# =============================================================================
# Usage
# =============================================================================

show_usage() {
    cat << EOF
Android Provisioning Suite v${VERSION}

USAGE:
    provision.sh [COMMAND] [OPTIONS]

COMMANDS:
    quick       Quick provisioning with sensible defaults (no prompts)
    apps        Install apps from an app set
    debloat     Remove bloatware using tier system
    config      Apply device-specific settings
    detect      Detect device and show info
    provision   Run full provisioning (interactive)
    setup-agent Configure device for headless/automated access
    connect     Connect to a device over the network (OTA, cable-free)
    fleet       Update a whole fleet unattended (scheduled, config + apps)
    enroll      Enroll a device into Headwind MDM (Device Owner, Phase 2)

GLOBAL OPTIONS:
    -d, --dry-run           Preview without making changes
    -f, --force             Skip confirmation prompts
    -S, --serial <id>       Use specific device (from 'adb devices')
    -h, --help              Show this help message
    -v, --version           Show version
    -l, --list-devices      List connected devices and exit

APPS OPTIONS:
    --set, -s <name>        App set to install (minimal, personal, work, testing)
    --list                  List available app sets
    --preview               Preview apps in set without installing

DEBLOAT OPTIONS:
    --level, -L <tier>      Debloat tier (light, standard, aggressive)
    --degoogle              Also remove Google apps (can combine with any tier)
    --list                  List available tiers

CONFIG OPTIONS:
    --device, -D <type>     Device profile (pixel, samsung, xiaomi, oneplus, m11, m9)

SETUP-AGENT OPTIONS:
    --wireless, -w          Also enable wireless ADB (TCP/IP mode)
    --persistent            Make wireless ADB persist across reboots (requires root)

CONNECT OPTIONS (over-the-network / cable-free):
    --ip <host[:port]>      Connect target (port defaults to 5555)
    --pair <host:port>      Android 11+ Wireless-debugging pairing endpoint
    --code <nnnnnn>         6-digit pairing code (with --pair)
    --from-usb              Flip a USB-attached device to TCP/IP, then connect
    --port <n>              TCP/IP port for --from-usb (default 5555)

FLEET OPTIONS (unattended, scheduled fleet updates):
    --inventory <file>      Device inventory (default: fleet/inventory.conf)
    -d, --dry-run           Preview every device's steps without writing

ENROLL OPTIONS (Phase 2 -- Headwind MDM Device Owner onboarding):
    --apk <file>            Path to hmdm.apk (default: apks/hmdm.apk)
    --server <url>          MDM server URL (default: https://mdm.kblab.me)
                            Also reads HMDM_SERVER_URL env var.
    -d, --dry-run           Preview steps without making changes

EXAMPLES:
    # Install personal app set
    provision.sh apps --set personal

    # Standard debloat, keep Google
    provision.sh debloat --level standard

    # Aggressive debloat with degoogling
    provision.sh debloat --level aggressive --degoogle

    # Apply Samsung-specific settings
    provision.sh config --device samsung

    # Full interactive provisioning
    provision.sh provision

    # Preview what would be debloated
    provision.sh debloat --level standard --dry-run

    # Configure device for agent/automated access
    provision.sh setup-agent --wireless

    # Update the whole fleet unattended (preview first, then for real)
    provision.sh fleet --dry-run
    provision.sh fleet

    # Connect to a wall tablet over Wi-Fi (cable-free), then provision it
    provision.sh connect --pair 192.168.1.60:3715 --code 481502 --ip 192.168.1.60:43001

    # Enroll a USB-attached device into Headwind MDM (Device Owner):
    #   1. Factory-reset (or remove all accounts) on the device first.
    #   2. Download hmdm.apk from the MDM console -> copy to apks/hmdm.apk.
    #   3. Plug in USB and run:
    provision.sh enroll --dry-run      # preview the steps
    provision.sh enroll                # run for real
    provision.sh config --device m11 -S 192.168.1.60:43001

APP SETS:
    minimal     Essential utilities only
    personal    Full personal phone setup
    work        Business/productivity apps
    testing     Development and debug tools

DEBLOAT TIERS (cumulative):
    light       Carrier bloat, unused services
    standard    + Vendor bloat (Bixby, MIUI apps)
    aggressive  + More system apps, some Google

DEVICE CONFIGS:
    pixel       Google Pixel (clean AOSP)
    samsung     Samsung Galaxy (OneUI)
    xiaomi      Xiaomi/Redmi/POCO (MIUI/HyperOS)
    oneplus     OnePlus (OxygenOS/ColorOS)
    m11         Lenovo Tab M11 — HA FreeKiosk wall panel (always-on)
    m9          Lenovo Tab M9  — HA FreeKiosk wall panel (always-on)
    default     Universal settings

For more info: https://github.com/kblack0610/android-suite
EOF
}

# =============================================================================
# Global Variables
# =============================================================================

COMMAND=""
DRY_RUN=0
FORCE=0

# Apps options
APP_SET=""
APP_LIST=0
APP_PREVIEW=0

# Debloat options
DEBLOAT_LEVEL="light"
DEGOOGLE=0
DEBLOAT_LIST=0

# Config options
DEVICE_CONFIG=""

# Device selection
DEVICE_SERIAL=""

# Setup-agent options
WIRELESS=0
PERSISTENT_WIRELESS=0

# Connect (OTA) options
CONNECT_IP=""
CONNECT_PAIR=""
CONNECT_CODE=""
CONNECT_FROM_USB=0
CONNECT_PORT=5555

# Fleet options
FLEET_INVENTORY=""

# Enroll options (Phase 2 -- Headwind MDM)
ENROLL_APK=""
HMDM_SERVER_URL="${HMDM_SERVER_URL:-https://mdm.kblab.me}"

# Legacy compatibility
PROFILE=""
SKIP_ROOT=0
PHASE=""

# =============================================================================
# Argument Parsing
# =============================================================================

parse_global_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            -l|--list-devices)
                log_section "Connected Devices"
                list_devices table
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "Android Provisioning Suite v${VERSION}"
                exit 0
                ;;
            *)
                # Unknown option, return remaining args
                echo "$@"
                return 0
                ;;
        esac
    done
}

parse_args() {
    # Parse global options first (before command)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            -S|--serial)
                DEVICE_SERIAL="$2"
                shift 2
                ;;
            -l|--list-devices)
                log_section "Connected Devices"
                list_devices table
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "Android Provisioning Suite v${VERSION}"
                exit 0
                ;;
            *)
                # Not a global option, must be command or command option
                break
                ;;
        esac
    done

    # Now first remaining arg is command
    if [[ $# -eq 0 ]]; then
        COMMAND="provision"
        return
    fi

    case "$1" in
        apps)
            COMMAND="apps"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -s|--set)
                        APP_SET="$2"
                        shift 2
                        ;;
                    --list)
                        APP_LIST=1
                        shift
                        ;;
                    --preview)
                        APP_PREVIEW=1
                        shift
                        ;;
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -f|--force)
                        FORCE=1
                        shift
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown apps option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        debloat)
            COMMAND="debloat"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -L|--level)
                        DEBLOAT_LEVEL="$2"
                        shift 2
                        ;;
                    --degoogle)
                        DEGOOGLE=1
                        shift
                        ;;
                    --list)
                        DEBLOAT_LIST=1
                        shift
                        ;;
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -f|--force)
                        FORCE=1
                        shift
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown debloat option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        config)
            COMMAND="config"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -D|--device)
                        DEVICE_CONFIG="$2"
                        shift 2
                        ;;
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -f|--force)
                        FORCE=1
                        shift
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown config option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        detect)
            COMMAND="detect"
            shift
            ;;
        connect)
            COMMAND="connect"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --ip)
                        CONNECT_IP="$2"
                        shift 2
                        ;;
                    --pair)
                        CONNECT_PAIR="$2"
                        shift 2
                        ;;
                    --code)
                        CONNECT_CODE="$2"
                        shift 2
                        ;;
                    --from-usb)
                        CONNECT_FROM_USB=1
                        shift
                        ;;
                    --port)
                        CONNECT_PORT="$2"
                        shift 2
                        ;;
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown connect option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        setup-agent)
            COMMAND="setup-agent"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -w|--wireless)
                        WIRELESS=1
                        shift
                        ;;
                    --persistent)
                        WIRELESS=1
                        PERSISTENT_WIRELESS=1
                        shift
                        ;;
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -f|--force)
                        FORCE=1
                        shift
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown setup-agent option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        fleet)
            COMMAND="fleet"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --inventory)
                        FLEET_INVENTORY="$2"
                        shift 2
                        ;;
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    *)
                        log_error "Unknown fleet option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        enroll)
            COMMAND="enroll"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --apk)
                        ENROLL_APK="$2"
                        shift 2
                        ;;
                    --server)
                        HMDM_SERVER_URL="$2"
                        shift 2
                        ;;
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown enroll option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        quick)
            COMMAND="quick"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown quick option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        provision|--interactive)
            COMMAND="provision"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -d|--dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -f|--force)
                        FORCE=1
                        shift
                        ;;
                    -s|--skip-root)
                        SKIP_ROOT=1
                        shift
                        ;;
                    # Legacy profile support
                    -p|--profile)
                        PROFILE="$2"
                        shift 2
                        ;;
                    -S|--serial)
                        DEVICE_SERIAL="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown provision option: $1"
                        exit 1
                        ;;
                esac
            done
            ;;
        # Legacy commands
        phase)
            COMMAND="phase"
            PHASE="$2"
            shift 2
            ;;
        settings)
            COMMAND="config"
            shift
            ;;
        install)
            COMMAND="apps"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--version)
            echo "Android Provisioning Suite v${VERSION}"
            exit 0
            ;;
        -l|--list-devices)
            log_section "Connected Devices"
            list_devices table
            exit 0
            ;;
        *)
            log_error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac

    # Export for phases
    export DRY_RUN FORCE DEGOOGLE DEBLOAT_LEVEL APP_SET DEVICE_CONFIG DEVICE_SERIAL
}

# =============================================================================
# Phase Running
# =============================================================================

run_phase() {
    local phase_num="$1"
    local phase_script="$SUITE_DIR/phases/0${phase_num}_*.sh"

    local script
    script=$(ls $phase_script 2>/dev/null | head -1)

    if [[ -z "$script" || ! -f "$script" ]]; then
        log_error "Phase $phase_num not found"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$script"

    case "$phase_num" in
        1) phase_handshake ;;
        2) phase_debloat ;;
        3) phase_install_apps ;;
        4) phase_apply_settings ;;
        5) phase_root_extras ;;
        *)
            log_error "Invalid phase: $phase_num"
            return 1
            ;;
    esac
}

# =============================================================================
# Command Handlers
# =============================================================================

cmd_apps() {
    # List app sets
    if [[ $APP_LIST -eq 1 ]]; then
        source "$SUITE_DIR/tools/app_installer.sh"
        list_app_sets
        return 0
    fi

    # Preview app set
    if [[ $APP_PREVIEW -eq 1 ]]; then
        if [[ -z "$APP_SET" ]]; then
            log_error "Specify app set with --set"
            exit 1
        fi
        source "$SUITE_DIR/tools/app_installer.sh"
        preview_app_set "$APP_SET"
        return 0
    fi

    # Install apps
    if [[ -z "$APP_SET" ]]; then
        log_error "Specify app set with --set (or use --list to see options)"
        exit 1
    fi

    log_section "Installing App Set: $APP_SET"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    # Phase 1: Handshake
    run_phase 1 || return 1

    # Install from manifest
    source "$SUITE_DIR/tools/app_installer.sh"
    install_from_manifest "$APP_SET"

    log_success "App installation complete"
}

cmd_debloat() {
    # List tiers
    if [[ $DEBLOAT_LIST -eq 1 ]]; then
        log_info "Available debloat tiers (cumulative):"
        echo "  light       Carrier bloat, unused services"
        echo "  standard    + Vendor bloat (Bixby, MIUI apps)"
        echo "  aggressive  + More system apps, some Google"
        echo ""
        echo "Additional flags:"
        echo "  --degoogle  Remove Google apps (combinable with any tier)"
        return 0
    fi

    log_section "Debloating: Level=$DEBLOAT_LEVEL, DeGoogle=$DEGOOGLE"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    # Phase 1: Handshake
    run_phase 1 || return 1

    # Phase 2: Debloat with tier system
    run_phase 2

    log_success "Debloat complete"
}

cmd_config() {
    if [[ -z "$DEVICE_CONFIG" ]]; then
        # Auto-detect from device
        run_phase 1 || return 1
        DEVICE_CONFIG="${SUGGESTED_PROFILE:-default}"
        log_info "Auto-detected device config: $DEVICE_CONFIG"
    fi

    log_section "Applying Config: $DEVICE_CONFIG"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    # Ensure phase 1 ran
    if [[ -z "${DEVICE_SERIAL:-}" ]]; then
        run_phase 1 || return 1
    fi

    # Set profile and run phase 4
    PROFILE="$DEVICE_CONFIG"
    export PROFILE
    load_profile "$PROFILE"
    run_phase 4

    log_success "Config applied"
}

cmd_detect() {
    source "$SUITE_DIR/tools/device_detect.sh"
    print_device_info
}

cmd_quick() {
    log_section "Quick Provisioning"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    # Set sensible defaults
    DEBLOAT_LEVEL="light"
    DEGOOGLE=0
    APP_SET="minimal"
    export DEBLOAT_LEVEL DEGOOGLE APP_SET

    # Run handshake
    run_phase 1 || return 1

    # Auto-detect config
    DEVICE_CONFIG="${SUGGESTED_PROFILE:-default}"
    PROFILE="$DEVICE_CONFIG"
    export PROFILE DEVICE_CONFIG
    load_profile "$PROFILE"

    log_info ""
    log_info "Quick provisioning with:"
    log_info "  Device config: $DEVICE_CONFIG"
    log_info "  Debloat: light (keeps Google)"
    log_info "  Apps: minimal"
    log_info ""

    # Phase 2: Debloat
    run_phase 2

    # Phase 3: Install Apps
    echo ""
    source "$SUITE_DIR/tools/app_installer.sh"
    install_from_manifest "$APP_SET"

    # Phase 4: Apply Settings
    echo ""
    run_phase 4

    log_section "Quick Provisioning Complete!"
    log_success "Device provisioned with sensible defaults"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Reboot device"
    log_info "  2. Sign into accounts"
}

cmd_provision() {
    log_section "Android Provisioning Suite v${VERSION}"
    log_info "Interactive Mode"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    # Phase 1: Handshake
    run_phase 1 || return 1

    echo ""
    local _friendly
    _friendly=$(device_short_name "$MODEL")
    log_info "Device: $_friendly ($MANUFACTURER $MODEL)"
    log_info "Android: $ANDROID_VERSION (SDK $SDK_VERSION)"
    log_info "Root: $ROOT_STATUS"
    log_info "Suggested profile: $SUGGESTED_PROFILE"
    echo ""

    # Device config selection
    if [[ -z "$DEVICE_CONFIG" ]]; then
        DEVICE_CONFIG="${SUGGESTED_PROFILE:-default}"
    fi
    if [[ $FORCE -eq 0 ]]; then
        read -rp "Device config [$DEVICE_CONFIG]: " input
        DEVICE_CONFIG="${input:-$DEVICE_CONFIG}"
    fi
    PROFILE="$DEVICE_CONFIG"
    export PROFILE DEVICE_CONFIG

    # Debloat level selection
    if [[ $FORCE -eq 0 ]]; then
        echo ""
        log_info "Debloat tiers: light, standard, aggressive"
        read -rp "Debloat level [$DEBLOAT_LEVEL]: " input
        DEBLOAT_LEVEL="${input:-$DEBLOAT_LEVEL}"

        read -rp "Remove Google services? [y/N]: " degoogle_choice
        [[ "$degoogle_choice" =~ ^[Yy] ]] && DEGOOGLE=1
    fi
    export DEBLOAT_LEVEL DEGOOGLE

    # App set selection
    if [[ $FORCE -eq 0 ]]; then
        echo ""
        log_info "App sets: minimal, personal, work, testing (or 'none')"
        read -rp "App set [minimal]: " input
        APP_SET="${input:-minimal}"
    else
        APP_SET="${APP_SET:-minimal}"
    fi
    export APP_SET

    # Confirmation
    echo ""
    log_info "Will apply:"
    log_info "  Device config: $DEVICE_CONFIG"
    log_info "  Debloat: $DEBLOAT_LEVEL $([ $DEGOOGLE -eq 1 ] && echo '+ degoogle' || echo '')"
    log_info "  App set: $APP_SET"
    echo ""

    if [[ $FORCE -eq 0 ]]; then
        if ! confirm "Proceed?"; then
            log_info "Provisioning cancelled"
            return 0
        fi
    fi

    # Load profile
    load_profile "$PROFILE"

    # Phase 2: Debloat
    echo ""
    run_phase 2

    # Phase 3: Install Apps
    if [[ "$APP_SET" != "none" ]]; then
        echo ""
        source "$SUITE_DIR/tools/app_installer.sh"
        install_from_manifest "$APP_SET"
    fi

    # Phase 4: Apply Settings
    echo ""
    run_phase 4

    # Phase 5: Root Extras (optional)
    if [[ $SKIP_ROOT -eq 0 && "${ROOT_STATUS:-none}" != "none" ]]; then
        echo ""
        if [[ $FORCE -eq 1 ]] || confirm "Run root-only extras (Phase 5)?"; then
            run_phase 5
        fi
    fi

    # Complete
    log_section "Provisioning Complete!"
    log_success "Device provisioned"
    log_info ""
    log_info "Summary:"
    log_info "  Config: $DEVICE_CONFIG"
    log_info "  Debloat: $DEBLOAT_LEVEL $([ $DEGOOGLE -eq 1 ] && echo '+ degoogle' || echo '')"
    log_info "  Apps: $APP_SET"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Reboot device"
    log_info "  2. Sign into accounts"
    log_info "  3. Configure app settings"
}

cmd_setup_agent() {
    log_section "Agent Access Setup"
    log_warning "WARNING: This disables security features!"
    log_warning "Only use on dedicated test devices."
    echo ""

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    # Check device connection
    if ! check_device; then
        return 1
    fi

    # Get device serial if not specified
    if [[ -z "$DEVICE_SERIAL" ]]; then
        DEVICE_SERIAL=$(get_device_serial) || return 1
    fi
    export DEVICE_SERIAL

    # Load security functions
    source "$SUITE_DIR/settings/security.sh"

    echo ""
    log_info "Configuring device: $DEVICE_SERIAL"
    echo ""

    local errors=0

    # 1. Disable lock screen
    log_info "Step 1/5: Disabling lock screen..."
    disable_lock_screen || ((errors++))

    # 2. Configure stay awake
    log_info "Step 2/5: Configuring stay awake..."
    configure_stay_awake || ((errors++))

    # 3. Grant shell root (if available)
    log_info "Step 3/5: Configuring root access..."
    grant_shell_root || true  # Don't fail if not rooted

    # 4. Pre-authorize this host's ADB key so headless/scheduled runs never need
    #    an on-device "Allow" tap. Requires root; on unrooted devices this is a
    #    no-op — instead connect once over USB and tap "Always allow from this
    #    computer" for THIS host's key (persists across reboots). See docs/fleet-runner.md
    log_info "Step 4/5: Pre-authorizing ADB key (headless auth)..."
    authorize_adb_key || true  # Non-fatal: unrooted uses the USB always-allow path

    # 5. Enable wireless ADB if requested
    if [[ $WIRELESS -eq 1 ]]; then
        log_info "Step 5/5: Enabling wireless ADB..."
        if [[ $PERSISTENT_WIRELESS -eq 1 ]]; then
            enable_persistent_wireless_adb || ((errors++))
        else
            enable_wireless_adb || ((errors++))
        fi
    else
        log_info "Step 5/5: Wireless ADB skipped (use --wireless to enable)"
    fi

    # Summary
    echo ""
    if [[ $errors -eq 0 ]]; then
        log_success "Device configured for agent access!"
    else
        log_warning "Setup completed with $errors warning(s)"
    fi

    echo ""
    log_info "Verification commands:"
    log_info "  adb shell whoami"
    log_info "  adb shell input tap 500 500"
    log_info "  adb shell dumpsys window | grep mCurrentFocus"
}

cmd_connect() {
    log_section "Connect Over Network (OTA)"

    if ! check_adb; then
        return 1
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    local target=""

    # Path 1: one-cable bootstrap (flip a USB device to TCP/IP, then connect)
    if [[ $CONNECT_FROM_USB -eq 1 ]]; then
        if ! check_device; then
            log_error "--from-usb needs a USB-connected, authorized device"
            return 1
        fi
        target=$(enable_wireless_adb "$CONNECT_PORT") || return 1

    # Path 2: Android 11+ Wireless-debugging pairing (fully cable-free)
    elif [[ -n "$CONNECT_PAIR" ]]; then
        if [[ -z "$CONNECT_CODE" ]]; then
            log_error "--pair requires --code <6-digit pairing code>"
            return 1
        fi
        adb_pair "$CONNECT_PAIR" "$CONNECT_CODE" || return 1

        # After pairing, connect. The connect port differs from the pairing port,
        # so --ip is needed (fall back to the pair host on the default port).
        if [[ -n "$CONNECT_IP" ]]; then
            target=$(adb_connect "$CONNECT_IP") || return 1
        else
            log_warning "No --ip given; trying the pair host on port $CONNECT_PORT"
            target=$(adb_connect "${CONNECT_PAIR%%:*}:$CONNECT_PORT") || {
                log_error "Provide --ip <host:port> from the Wireless-debugging screen"
                return 1
            }
        fi

    # Path 3: plain connect (tcpip/wireless-debugging already on)
    elif [[ -n "$CONNECT_IP" ]]; then
        target=$(adb_connect "$CONNECT_IP") || return 1

    else
        log_error "Specify one of: --ip <host[:port]>, --pair <host:port> --code <n>, or --from-usb"
        return 1
    fi

    # Handshake over the network so the user sees the device + suggested profile
    if [[ $DRY_RUN -eq 0 ]]; then
        export DEVICE_SERIAL="$target"
        echo ""
        run_phase 1 || return 1
    fi

    echo ""
    log_success "Device reachable over the network: $target"
    log_info "Now provision it with that serial, e.g.:"
    log_info "  ./provision.sh debloat --level aggressive -S $target"
    log_info "  ./provision.sh config  --device m11        -S $target"
}

# =============================================================================
# Entry Point
# =============================================================================

main() {
    parse_args "$@"

    case "$COMMAND" in
        apps)
            cmd_apps
            ;;
        debloat)
            cmd_debloat
            ;;
        config)
            cmd_config
            ;;
        detect)
            cmd_detect
            ;;
        quick)
            cmd_quick
            ;;
        provision)
            cmd_provision
            ;;
        setup-agent)
            cmd_setup_agent
            ;;
        connect)
            cmd_connect
            ;;
        fleet)
            source "$SUITE_DIR/tools/fleet_runner.sh"
            cmd_fleet
            ;;
        enroll)
            export ENROLL_APK HMDM_SERVER_URL
            source "$SUITE_DIR/tools/enroll.sh"
            cmd_enroll
            ;;
        phase)
            if [[ -z "$PHASE" ]]; then
                log_error "Phase number required"
                exit 1
            fi
            run_phase "$PHASE"
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
