#!/usr/bin/env bash
# Settings Library: Security & Developer Options
# Configure developer settings, ADB, and security-related options

# Keep screen on while charging
# Args: mode (0=off, 1=AC, 2=USB, 3=both, 4=wireless, 7=all)
enable_stay_awake_charging() {
    local mode="${1:-3}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would enable stay awake while charging (mode: $mode)"
        return 0
    fi

    log_info "Enabling stay awake while charging"
    setting_put global stay_on_while_plugged_in "$mode"
    log_success "Screen will stay on while charging"
}

# Disable stay awake while charging
disable_stay_awake_charging() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would disable stay awake while charging"
        return 0
    fi

    log_info "Disabling stay awake while charging"
    setting_put global stay_on_while_plugged_in 0
    log_success "Stay awake disabled"
}

# Enable/disable haptic feedback
set_haptic_feedback() {
    local enabled="${1:-1}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set haptic feedback to $enabled"
        return 0
    fi

    if [[ "$enabled" == "1" ]]; then
        log_info "Enabling haptic feedback"
    else
        log_info "Disabling haptic feedback"
    fi

    setting_put system haptic_feedback_enabled "$enabled"
    log_success "Haptic feedback $([ "$enabled" == "1" ] && echo "enabled" || echo "disabled")"
}

# Enable/disable touch sounds
set_touch_sounds() {
    local enabled="${1:-1}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set touch sounds to $enabled"
        return 0
    fi

    if [[ "$enabled" == "1" ]]; then
        log_info "Enabling touch sounds"
    else
        log_info "Disabling touch sounds"
    fi

    setting_put system sound_effects_enabled "$enabled"
    log_success "Touch sounds $([ "$enabled" == "1" ] && echo "enabled" || echo "disabled")"
}

# Show developer options status
show_developer_options() {
    local dev_enabled
    dev_enabled=$(setting_get global development_settings_enabled 2>/dev/null || echo "0")

    if [[ "$dev_enabled" == "1" ]]; then
        log_info "Developer Options: ENABLED"
    else
        log_warning "Developer Options: DISABLED"
        log_info "Enable in Settings > About Phone > Tap Build Number 7 times"
    fi
}

# Enable USB debugging (requires Developer Options enabled)
enable_usb_debugging() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would enable USB debugging"
        return 0
    fi

    log_info "Enabling USB debugging"
    setting_put global adb_enabled 1
    log_success "USB debugging enabled"
}

# Grant permission to an app
# Args: package_name permission
grant_permission() {
    local package="${1:-}"
    local permission="${2:-}"

    if [[ -z "$package" || -z "$permission" ]]; then
        log_error "Usage: grant_permission <package> <permission>"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would grant $permission to $package"
        return 0
    fi

    log_info "Granting $permission to $package"
    adb_cmd shell pm grant "$package" "$permission" 2>/dev/null || {
        log_error "Failed to grant permission"
        return 1
    }
    log_success "Permission granted"
}

# Revoke permission from an app
# Args: package_name permission
revoke_permission() {
    local package="${1:-}"
    local permission="${2:-}"

    if [[ -z "$package" || -z "$permission" ]]; then
        log_error "Usage: revoke_permission <package> <permission>"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would revoke $permission from $package"
        return 0
    fi

    log_info "Revoking $permission from $package"
    adb_cmd shell pm revoke "$package" "$permission" 2>/dev/null || {
        log_error "Failed to revoke permission"
        return 1
    }
    log_success "Permission revoked"
}

# =============================================================================
# Agent Access Functions
# For configuring devices for headless/automated access
# =============================================================================

# Disable lock screen entirely (for test devices)
disable_lock_screen() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would disable lock screen"
        return 0
    fi

    log_info "Disabling lock screen..."

    # Try locksettings command first (most reliable)
    if adb_cmd shell locksettings set-disabled true 2>/dev/null; then
        log_success "Lock screen disabled"
        return 0
    fi

    # Fallback: try settings approach
    if adb_cmd shell settings put secure lockscreen.disabled 1 2>/dev/null; then
        log_success "Lock screen disabled (via settings)"
        return 0
    fi

    log_warning "Could not disable lock screen - may need manual intervention"
    log_info "  Settings > Security > Screen Lock > None"
    return 1
}

# Clear existing PIN/password (requires knowing current PIN)
# Usage: clear_lock_pin "1234"
clear_lock_pin() {
    local current_pin="${1:-}"

    if [[ -z "$current_pin" ]]; then
        log_error "Usage: clear_lock_pin <current_pin>"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would clear lock PIN"
        return 0
    fi

    log_info "Clearing lock PIN..."
    if adb_cmd shell locksettings clear --old "$current_pin" 2>/dev/null; then
        log_success "Lock PIN cleared"
        return 0
    else
        log_error "Failed to clear PIN - is the PIN correct?"
        return 1
    fi
}

# Configure stay awake while charging (for test devices)
configure_stay_awake() {
    local mode="${1:-3}"  # 3 = AC + USB

    if is_dry_run; then
        log_info "[DRY-RUN] Would configure stay awake (mode: $mode)"
        return 0
    fi

    log_info "Configuring stay awake while charging..."
    setting_put global stay_on_while_plugged_in "$mode"

    # Also disable lock timeout
    setting_put secure lock_screen_lock_after_timeout 0 2>/dev/null || true

    log_success "Device will stay awake while charging"
}

# Grant shell permanent root access (Magisk)
grant_shell_root() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would grant shell root access"
        return 0
    fi

    # Check if device is rooted
    if ! adb_cmd shell "su -c 'id'" 2>/dev/null | grep -q "uid=0"; then
        log_warning "Device does not appear to be rooted - skipping"
        return 0
    fi

    log_info "Granting shell permanent root access..."

    # Magisk method
    if adb_cmd shell su -c 'magisk --sqlite "UPDATE policies SET policy=2 WHERE uid=2000"' 2>/dev/null; then
        log_success "Shell root access granted (Magisk)"
        return 0
    fi

    # KernelSU typically auto-grants shell, just verify
    if adb_cmd shell su -c 'which ksud' 2>/dev/null | grep -q "ksud"; then
        log_info "KernelSU detected - shell access should be automatic"
        return 0
    fi

    log_warning "Could not configure root access - grant manually in Magisk/KSU app"
    return 1
}

# Pre-authorize ADB key (requires root)
authorize_adb_key() {
    local key_file="${1:-$HOME/.android/adbkey.pub}"

    if [[ ! -f "$key_file" ]]; then
        log_error "ADB public key not found: $key_file"
        log_info "Generate with: adb keygen ~/.android/adbkey"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would authorize ADB key from $key_file"
        return 0
    fi

    log_info "Authorizing ADB key..."

    local key_content
    key_content=$(cat "$key_file")

    # This requires root access
    if adb_cmd shell su -c "echo '$key_content' >> /data/misc/adb/adb_keys" 2>/dev/null; then
        log_success "ADB key authorized"
        return 0
    else
        log_warning "Could not authorize key - requires root access"
        log_info "Manually accept the RSA fingerprint prompt on device"
        return 1
    fi
}

# Master function: Configure device for agent/automated access
configure_agent_access() {
    local wireless="${1:-false}"

    log_section "Configuring Agent Access"
    log_warning "WARNING: This disables security features. Use only on test devices!"
    echo ""

    local errors=0

    # Disable lock screen
    disable_lock_screen || ((errors++))

    # Stay awake while charging
    configure_stay_awake || ((errors++))

    # Grant root access if available
    grant_shell_root || true  # Don't count as error if not rooted

    # Enable wireless ADB if requested
    if [[ "$wireless" == "true" ]]; then
        enable_wireless_adb || ((errors++))
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        log_success "Device configured for agent access"
    else
        log_warning "Agent setup completed with $errors warning(s)"
    fi

    return 0
}
