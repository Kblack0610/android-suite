#!/usr/bin/env bash
# Phase 3: Install Apps
# Install apps from app-sets using manifest system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Phase 3: Install Apps (App-Sets System)
# =============================================================================

phase_install_apps() {
    log_section "Phase 3: Install Apps"

    if ! check_device; then
        log_error "No device connected"
        return 1
    fi

    local app_set="${APP_SET:-}"
    local apks_dir="$SCRIPT_DIR/../apks"
    local app_sets_dir="$SCRIPT_DIR/../app-sets"

    # If no app set specified, check for fallback behavior
    if [[ -z "$app_set" ]]; then
        # Check if any APKs exist in apks/ directory (legacy behavior)
        local apk_files
        mapfile -t apk_files < <(find "$apks_dir" -maxdepth 1 -name "*.apk" -type f 2>/dev/null | sort)

        if [[ ${#apk_files[@]} -gt 0 ]]; then
            log_info "No app set specified, but found ${#apk_files[@]} APK(s) in apks/"
            log_info "Installing all APKs from apks/ directory..."
            echo ""

            if is_dry_run; then
                log_warning "DRY-RUN MODE - No apps will be installed"
                for apk in "${apk_files[@]}"; do
                    log_info "[DRY-RUN] Would install: $(basename "$apk")"
                done
                return 0
            fi

            if [[ "${FORCE:-0}" != "1" ]]; then
                if ! confirm "Install all ${#apk_files[@]} APKs?"; then
                    log_info "Installation cancelled"
                    return 0
                fi
            fi

            local installed=0
            local failed=0

            for apk in "${apk_files[@]}"; do
                if install_apk "$apk"; then
                    ((++installed)) || true
                else
                    ((++failed)) || true
                fi
            done

            log_section "Installation Summary"
            log_info "Installed: $installed"
            log_info "Failed: $failed"
            return 0
        fi

        # No APKs and no app set specified
        log_warning "No app set specified and no APKs in apks/ directory"
        log_info ""
        log_info "To install apps, either:"
        log_info "  1. Specify an app set: provision.sh apps --set personal"
        log_info "  2. Place APK files in: $apks_dir/"
        log_info ""
        log_info "Available app sets:"
        for set_file in "$app_sets_dir"/*.txt; do
            [[ -f "$set_file" ]] || continue
            local set_name
            set_name=$(basename "$set_file" .txt)
            echo "  - $set_name"
        done
        return 0
    fi

    # Use app-sets system
    log_info "App set: $app_set"

    # Source the app installer
    source "$SCRIPT_DIR/../tools/app_installer.sh"

    # Check if app set exists
    local manifest_file="$app_sets_dir/${app_set}.txt"
    if [[ ! -f "$manifest_file" ]]; then
        log_error "App set not found: $app_set"
        log_info ""
        log_info "Available app sets:"
        for set_file in "$app_sets_dir"/*.txt; do
            [[ -f "$set_file" ]] || continue
            local set_name
            set_name=$(basename "$set_file" .txt)
            echo "  - $set_name"
        done
        return 1
    fi

    if is_dry_run; then
        log_warning "DRY-RUN MODE - No apps will be installed"
    fi

    # Preview what will be installed
    log_info ""
    log_info "Packages to install:"
    preview_app_set "$app_set"
    log_info ""

    if ! is_dry_run && [[ "${FORCE:-0}" != "1" ]]; then
        if ! confirm "Install apps from '$app_set' set?"; then
            log_info "Installation cancelled"
            return 0
        fi
    fi

    # Install from manifest
    install_from_manifest "$app_set"

    log_section "App Installation Complete"
    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    phase_install_apps
fi
