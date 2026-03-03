#!/usr/bin/env bash
# Settings Library: App-Specific Configuration
# Configure installed apps via ADB intents and settings

MATERIAL_FILES_PKG="me.zhanghai.android.files"
MATERIAL_FILES_SMB_ACTIVITY="${MATERIAL_FILES_PKG}/.storage.EditSmbServerActivity"

# Load NAS configuration from profiles/nas.conf
# Sets NAS_* variables if config file exists and is valid
load_nas_config() {
    local config_file="$SCRIPT_DIR/../profiles/nas.conf"

    if [[ ! -f "$config_file" ]]; then
        log_info "No NAS config found (copy profiles/nas.conf.example to profiles/nas.conf)"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$config_file"

    if [[ "${NAS_ENABLED:-0}" != "1" ]]; then
        log_info "NAS configuration disabled (NAS_ENABLED != 1)"
        return 1
    fi

    if [[ -z "${NAS_HOST:-}" ]]; then
        log_error "NAS config missing required field: NAS_HOST"
        return 1
    fi

    if [[ -z "${NAS_PATH:-}" ]]; then
        log_error "NAS config missing required field: NAS_PATH"
        return 1
    fi

    return 0
}

# Launch the Material Files "Add SMB Server" screen via ADB intent
launch_smb_add_screen() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would launch Material Files SMB add screen"
        return 0
    fi

    log_info "Launching Material Files SMB server screen..."

    # Try launching the EditSmbServerActivity directly
    if adb_cmd shell am start -n "$MATERIAL_FILES_SMB_ACTIVITY" 2>/dev/null; then
        log_success "SMB server screen opened on device"
        return 0
    fi

    # Fallback: open Material Files main activity
    log_warning "Could not open SMB screen directly, opening Material Files..."
    if adb_cmd shell am start -n "${MATERIAL_FILES_PKG}/.app.MainActivity" 2>/dev/null; then
        log_info "Material Files opened — navigate to: + > Add storage > SMB server"
        return 0
    fi

    log_error "Failed to launch Material Files"
    return 1
}

# Print SMB connection details to terminal for user to enter on device
print_smb_instructions() {
    echo ""
    log_section "SMB Server Details"
    log_info "Enter these details on the device:"
    echo ""
    log_info "  Host:     ${NAS_HOST}"
    log_info "  Port:     ${NAS_PORT:-445}"
    log_info "  Path:     ${NAS_PATH}"
    log_info "  Name:     ${NAS_DISPLAY_NAME:-SMB Server}"

    if [[ "${NAS_AUTH_MODE:-guest}" == "guest" ]]; then
        log_info "  Auth:     Anonymous / Guest"
    else
        log_info "  Username: ${NAS_USERNAME:-}"
        if [[ -n "${NAS_PASSWORD:-}" ]]; then
            log_info "  Password: (set in nas.conf)"
        fi
    fi
    echo ""
}

# Master function: Configure Material Files SMB server
# Called from Phase 4 (04_apply_settings.sh)
configure_material_files_smb() {
    # Check if Material Files is installed
    if ! is_dry_run && ! is_package_installed "$MATERIAL_FILES_PKG"; then
        log_info "Material Files not installed — skipping SMB configuration"
        return 0
    fi

    # Load NAS config
    if ! load_nas_config; then
        return 0
    fi

    log_info "Configuring Material Files SMB server..."

    if is_dry_run; then
        log_info "[DRY-RUN] Would configure Material Files SMB server:"
        log_info "  Host: ${NAS_HOST}:${NAS_PORT:-445}/${NAS_PATH}"
        log_info "  Auth: ${NAS_AUTH_MODE:-guest}"
        return 0
    fi

    # Launch the SMB add screen on the device
    launch_smb_add_screen

    # Show connection details in terminal
    print_smb_instructions

    # Wait for user confirmation (skip with --force)
    confirm "Press Enter when done configuring SMB on device" "y"

    log_success "Material Files SMB configuration complete"
    return 0
}
