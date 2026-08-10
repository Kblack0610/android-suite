#!/usr/bin/env bash
# Settings Library: Kiosk / Wall-Panel
# Turns a tablet into an always-on Home Assistant wall panel running FreeKiosk.
#
# Composes existing helpers from security.sh / power.sh / display.sh (phase 4 sources
# those before calling a profile's apply_custom_settings, but we defensively source
# them too so this lib works if sourced standalone).

KIOSK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure dependency libs are available (idempotent — safe to re-source)
for _kiosk_dep in security power display; do
    if [[ -f "$KIOSK_LIB_DIR/${_kiosk_dep}.sh" ]]; then
        # shellcheck disable=SC1090
        source "$KIOSK_LIB_DIR/${_kiosk_dep}.sh"
    fi
done
unset _kiosk_dep

# Resolve the installed kiosk-app package.
# Precedence: explicit $KIOSK_PACKAGE override > on-device detection > documented fallback.
# The home-config runbook is ambiguous (com.freekiosk vs uk.freekiosk), so we detect live.
detect_kiosk_package() {
    if [[ -n "${KIOSK_PACKAGE:-}" ]]; then
        echo "$KIOSK_PACKAGE"
        return 0
    fi

    local pkg
    pkg=$(adb_cmd shell pm list packages 2>/dev/null \
        | sed 's/^package://' | tr -d '\r' \
        | grep -iE 'freekiosk|kiosk' | head -1)

    if [[ -n "$pkg" ]]; then
        echo "$pkg"
    else
        echo "uk.freekiosk"   # documented fallback (verify with: pm list packages | grep -i kiosk)
    fi
}

# Keep Wi-Fi connected while the screen is off (best-effort).
# Deprecated/removed on newer Android — harmless no-op there, and moot once the
# panel stays awake on the charger anyway.
set_wifi_never_sleep() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would set Wi-Fi to never sleep"
        return 0
    fi

    log_info "Keeping Wi-Fi on during sleep (best-effort)"
    setting_put global wifi_sleep_policy 2 2>/dev/null \
        || log_debug "wifi_sleep_policy not settable on this Android version (ok)"
    return 0
}

# Grant the kiosk webview the microphone permission (for the HA voice satellite /
# dashboard mic) and whitelist it from battery optimization so it never gets killed.
grant_kiosk_mic() {
    local pkg
    pkg=$(detect_kiosk_package)

    if is_dry_run; then
        log_info "[DRY-RUN] Would grant RECORD_AUDIO to '$pkg' and whitelist it from battery optimization"
        return 0
    fi

    if ! is_package_installed "$pkg"; then
        log_warning "Kiosk app '$pkg' not installed — skipping mic grant + battery whitelist"
        log_info "  Install FreeKiosk, then re-run: provision.sh config --device <m11|m9>"
        return 0
    fi

    log_info "Granting microphone permission to $pkg (voice satellite / dashboard mic)"
    grant_permission "$pkg" android.permission.RECORD_AUDIO \
        || log_warning "Could not grant RECORD_AUDIO to $pkg — grant it in the app if voice fails"

    whitelist_battery_optimization "$pkg" || true
    return 0
}

# Master: apply the always-on wall-panel OS tuning.
# Called from a kiosk profile's apply_custom_settings().
apply_kiosk_common() {
    log_section "Kiosk Wall-Panel Settings"

    # Screen: never lock, never sleep on the charger
    disable_lock_screen || true
    configure_stay_awake 7 || true     # 7 = AC + USB + wireless; screen stays on while charging
    set_screen_timeout "${SCREEN_TIMEOUT:-1800000}" || true

    # Network + liveness
    set_wifi_never_sleep || true
    grant_kiosk_mic || true

    log_success "Kiosk wall-panel OS tuning applied"
    log_info "Manual (not ADB-settable): FreeKiosk start URL / set-as-home / exit-PIN"
    log_info "  See: docs/kiosk-m11-m9.md and ~/dev/home/home-config/docs/wall-panels.md"
}
