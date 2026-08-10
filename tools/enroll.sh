#!/usr/bin/env bash
# Headwind MDM Enroll -- Phase 2 onboarding
#
# Turns a device into a Headwind MDM Device Owner client over USB:
#   1. Install the Headwind launcher APK (hmdm.apk from the apks/ dir).
#   2. Clear all accounts from the device (required by Android DPM).
#   3. Set the Headwind app as Device Owner via `adb shell dpm set-device-owner`.
#   4. Launch the app once so it can complete its own enrollment with the MDM server.
#
# IMPORTANT: Device Owner can only be set on a device with NO accounts. This
# means:
#   - Factory-fresh device  OR
#   - Device that had all accounts removed (Settings -> Accounts -> Remove All)
#
# After enrollment the device is managed by Headwind MDM for day-2 ops:
#   - Silent app install / update
#   - Kiosk lock-task (replaces manual kiosk config)
#   - SystemUpdatePolicy (automated OS OTA in a maintenance window; OEM-dependent)
#
# The Phase-1 fleet runner remains the fallback for devices that cannot be
# Device Owner (e.g. a phone that keeps a personal account).

# Resolve suite dir when sourced (provision.sh sets SUITE_DIR) or run standalone.
if [[ -z "${SUITE_DIR:-}" ]]; then
    SUITE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fi

# Headwind launcher package and DeviceAdminReceiver (confirmed from init SQL).
HMDM_PACKAGE="com.hmdm.launcher"
HMDM_RECEIVER="${HMDM_PACKAGE}/.AdminReceiver"

# Default APK path (user drops hmdm.apk into the apks/ dir).
HMDM_APK_DEFAULT="$SUITE_DIR/apks/hmdm.apk"

# MDM server URL (used when launching the app for the first time).
HMDM_SERVER_URL="${HMDM_SERVER_URL:-https://mdm.kblab.me}"

# ---------------------------------------------------------------------------
# Check that the device has no accounts; Device Owner requires a clean slate.
# ---------------------------------------------------------------------------
enroll_check_accounts() {
    local serial="$1"
    local accounts
    accounts=$(adb -s "$serial" shell dumpsys account 2>/dev/null | grep -c "Account {" || true)
    if [[ "${accounts:-0}" -gt 0 ]]; then
        log_error "Device has $accounts account(s) configured."
        log_error "Device Owner cannot be set while accounts exist."
        log_error "Remove all accounts via Settings -> Accounts, then re-run."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Check whether Device Owner is already set (idempotent guard).
# ---------------------------------------------------------------------------
enroll_is_device_owner() {
    local serial="$1"
    adb -s "$serial" shell dpm list-owners 2>/dev/null | grep -q "$HMDM_PACKAGE"
}

# ---------------------------------------------------------------------------
# Main enroll command.
# ---------------------------------------------------------------------------
cmd_enroll() {
    log_section "Headwind MDM Enroll"

    if ! check_adb; then
        return 1
    fi

    local apk="${ENROLL_APK:-$HMDM_APK_DEFAULT}"

    # -- Dry-run: show plan without needing a live device
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[DRY-RUN] MDM server: $HMDM_SERVER_URL"
        log_info "[DRY-RUN] APK: $apk"
        log_info "[DRY-RUN] Steps that would run:"
        log_info "  1. Check device has no accounts (required by DPM)"
        log_info "  2. adb install -r $apk"
        log_info "  3. adb shell dpm set-device-owner $HMDM_RECEIVER"
        log_info "  4. Launch $HMDM_PACKAGE to complete MDM enrollment"
        return 0
    fi

    # Resolve the target device serial (requires a live device).
    local serial
    serial=$(get_device_serial) || return 1

    log_info "Target device: $serial"
    log_info "MDM server: $HMDM_SERVER_URL"
    log_info "APK: $apk"
    echo "" >&2

    # -- Guard: APK must exist
    if [[ ! -f "$apk" ]]; then
        log_error "Headwind launcher APK not found: $apk"
        log_info "Download it from your MDM server:"
        log_info "  curl -L ${HMDM_SERVER_URL}/launcher.apk -o ${apk}"
        log_info "Or set ENROLL_APK=/path/to/hmdm.apk when running enroll."
        return 1
    fi

    # -- Guard: already enrolled?
    if enroll_is_device_owner "$serial"; then
        log_warning "Device Owner already set to $HMDM_PACKAGE -- nothing to do."
        log_info "If you need to re-enroll, first clear Device Owner:"
        log_info "  adb -s $serial shell dpm remove-active-admin ${HMDM_PACKAGE}/.AdminReceiver"
        return 0
    fi

    # -- Step 1: Check accounts
    log_section "Step 1/4 -- Check accounts"
    enroll_check_accounts "$serial" || return 1
    log_success "No accounts found -- safe to set Device Owner"

    # -- Step 2: Install launcher APK
    log_section "Step 2/4 -- Install Headwind launcher"
    if adb -s "$serial" install -r "$apk"; then
        log_success "Launcher installed"
    else
        log_error "APK install failed"
        return 1
    fi

    # -- Step 3: Set Device Owner
    log_section "Step 3/4 -- Set Device Owner"
    log_info "Running: adb -s $serial shell dpm set-device-owner $HMDM_RECEIVER"
    local dpm_out
    if dpm_out=$(adb -s "$serial" shell dpm set-device-owner "$HMDM_RECEIVER" 2>&1); then
        log_success "Device Owner set: $HMDM_PACKAGE"
    else
        log_error "dpm set-device-owner failed:"
        log_error "  $dpm_out"
        log_error ""
        log_error "Common causes:"
        log_error "  - Device still has accounts (remove via Settings -> Accounts)"
        log_error "  - Device is not fresh / previously had Device Owner removed"
        log_error "  - APK was not installed successfully"
        return 1
    fi

    # -- Step 4: Launch the app (completes enrollment with MDM server)
    log_section "Step 4/4 -- Launch Headwind launcher"
    log_info "Launching $HMDM_PACKAGE to start MDM enrollment..."
    adb -s "$serial" shell monkey -p "$HMDM_PACKAGE" -c android.intent.category.LAUNCHER 1 \
        > /dev/null 2>&1 || true
    log_success "App launched. On the device, follow the enrollment prompt."
    log_info "The app will connect to: $HMDM_SERVER_URL"
    log_info ""
    log_info "After enrollment the device is managed by Headwind MDM."
    log_info "Day-2 app updates, config, and OS OTA run through the MDM console."
    log_info "Console: $HMDM_SERVER_URL"

    log_section "Enroll complete"
}

# Standalone CLI: `tools/enroll.sh [--serial <id>] [--apk <path>] [--server <url>] [--dry-run]`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "$SUITE_DIR/base_functions.sh"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -S|--serial)  DEVICE_SERIAL="$2"; shift 2 ;;
            --apk)        ENROLL_APK="$2"; shift 2 ;;
            --server)     HMDM_SERVER_URL="$2"; shift 2 ;;
            -d|--dry-run) DRY_RUN=1; shift ;;
            -h|--help)
                echo "Usage: enroll.sh [--serial <id>] [--apk <path>] [--server <url>] [--dry-run]"
                echo ""
                echo "Env vars: HMDM_SERVER_URL, ENROLL_APK, DEVICE_SERIAL"
                exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    export DRY_RUN="${DRY_RUN:-0}"
    cmd_enroll
fi
