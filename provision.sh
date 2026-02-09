#!/usr/bin/env bash
# Android Provisioning Suite - Main Orchestrator
# Independent dimensions: apps, debloat, config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/base_functions.sh"

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
    apps        Install apps from an app set
    debloat     Remove bloatware using tier system
    config      Apply device-specific settings
    detect      Detect device and show info
    provision   Run full provisioning (interactive)

GLOBAL OPTIONS:
    -d, --dry-run           Preview without making changes
    -f, --force             Skip confirmation prompts
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
    --device, -D <type>     Device profile (pixel, samsung, xiaomi, oneplus)

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
DEBLOAT_LEVEL="standard"
DEGOOGLE=0
DEBLOAT_LIST=0

# Config options
DEVICE_CONFIG=""

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
                adb devices -l
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
    # First arg is command
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
            adb devices -l
            exit 0
            ;;
        *)
            log_error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac

    # Export for phases
    export DRY_RUN FORCE DEGOOGLE DEBLOAT_LEVEL APP_SET DEVICE_CONFIG
}

# =============================================================================
# Phase Running
# =============================================================================

run_phase() {
    local phase_num="$1"
    local phase_script="$SCRIPT_DIR/phases/0${phase_num}_*.sh"

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
        source "$SCRIPT_DIR/tools/app_installer.sh"
        list_app_sets
        return 0
    fi

    # Preview app set
    if [[ $APP_PREVIEW -eq 1 ]]; then
        if [[ -z "$APP_SET" ]]; then
            log_error "Specify app set with --set"
            exit 1
        fi
        source "$SCRIPT_DIR/tools/app_installer.sh"
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
    source "$SCRIPT_DIR/tools/app_installer.sh"
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
    source "$SCRIPT_DIR/tools/device_detect.sh"
    print_device_info
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
    log_info "Device: $MANUFACTURER $MODEL"
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
        source "$SCRIPT_DIR/tools/app_installer.sh"
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
        provision)
            cmd_provision
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
