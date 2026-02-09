#!/usr/bin/env bash
# Phase 2: Debloat
# Remove bloatware using tiered debloat system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Phase 2: Debloat (Tier System)
# =============================================================================

# Load debloat list from file, handling @include directives
load_debloat_list() {
    local list_file="$1"
    local already_included="${2:-}"

    if [[ ! -f "$list_file" ]]; then
        log_warning "Debloat list not found: $list_file"
        return
    fi

    # Prevent circular includes
    if [[ "$already_included" == *"$list_file"* ]]; then
        return
    fi
    already_included="${already_included}:${list_file}"

    local dir
    dir=$(dirname "$list_file")

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*#.*$ ]] && continue
        [[ -z "${line// }" ]] && continue

        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Handle @include directive
        if [[ "$line" =~ ^@include[[:space:]]+(.+)$ ]]; then
            local include_file="${BASH_REMATCH[1]}"
            local include_path

            # Resolve relative path
            if [[ "$include_file" != /* ]]; then
                include_path="$dir/$include_file"
            else
                include_path="$include_file"
            fi

            # Recursively load included file
            load_debloat_list "$include_path" "$already_included"
            continue
        fi

        # Output package name
        echo "$line"
    done < "$list_file"
}

# Map device to vendor name
get_vendor_name() {
    local manufacturer="${MANUFACTURER:-unknown}"
    manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]')

    case "$manufacturer" in
        samsung)
            echo "samsung"
            ;;
        xiaomi|redmi|poco)
            echo "xiaomi"
            ;;
        oneplus|oppo|realme)
            echo "oneplus"
            ;;
        google)
            echo "pixel"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Debloat using package list
debloat_packages() {
    local packages=("$@")
    local total=${#packages[@]}
    local removed=0
    local skipped=0
    local failed=0

    log_info "Processing $total packages..."

    for package in "${packages[@]}"; do
        if is_dry_run; then
            log_info "[DRY-RUN] Would remove: $package"
            ((removed++))
            continue
        fi

        if ! is_package_installed "$package"; then
            log_debug "Not installed, skipping: $package"
            ((skipped++))
            continue
        fi

        log_info "Removing: $package"
        if uninstall_package "$package" true; then
            log_success "Removed: $package"
            ((removed++))
        else
            log_warning "Failed to remove: $package"
            ((failed++))
        fi
    done

    log_section "Debloat Summary"
    log_info "Removed: $removed"
    log_info "Skipped (not installed): $skipped"
    log_info "Failed: $failed"
}

# Check for UAD export file
check_uad_export() {
    local exports_dir="$SCRIPT_DIR/../debloat-lists/uad-exports"
    local exports
    exports=$(find "$exports_dir" -name "*.txt" -type f 2>/dev/null | head -5)

    if [[ -n "$exports" ]]; then
        log_info "Found UAD exports:"
        echo "$exports" | while read -r f; do
            log_info "  - $(basename "$f")"
        done
        return 0
    fi
    return 1
}

phase_debloat() {
    log_section "Phase 2: Debloat"

    if ! check_device; then
        log_error "No device connected"
        return 1
    fi

    local debloat_dir="$SCRIPT_DIR/../debloat-lists"
    local level="${DEBLOAT_LEVEL:-standard}"
    local degoogle="${DEGOOGLE:-0}"
    local all_packages=()

    # Validate tier
    local valid_tiers="light standard aggressive"
    if [[ ! " $valid_tiers " =~ " $level " ]]; then
        log_error "Invalid debloat level: $level"
        log_info "Valid levels: $valid_tiers"
        return 1
    fi

    log_info "Debloat level: $level"
    log_info "DeGoogle: $([ "$degoogle" == "1" ] && echo "yes" || echo "no")"

    # Step 1: Check for UAD exports first
    log_info ""
    log_info "Checking for UAD exported profiles..."
    if check_uad_export; then
        log_info ""
        log_info "UAD exports found. You can use Universal Android Debloater to:"
        log_info "  1. Import your saved profile"
        log_info "  2. Apply removals with one click"
        log_info ""
        log_info "Download UAD: https://github.com/0x192/universal-android-debloater"
        log_info ""

        if ! is_dry_run && [[ "${FORCE:-0}" != "1" ]]; then
            if ! confirm "Continue with built-in debloat lists instead?"; then
                log_info "Use UAD to debloat, then run phase 3"
                return 0
            fi
        fi
    fi

    # Step 2: Load tier file (handles @include for cumulative tiers)
    log_info ""
    log_info "Loading debloat lists..."

    local tier_file="$debloat_dir/tiers/${level}.txt"
    if [[ -f "$tier_file" ]]; then
        log_info "Loading tier: $level"
        mapfile -t tier_packages < <(load_debloat_list "$tier_file")
        all_packages+=("${tier_packages[@]}")
    else
        log_warning "Tier file not found: $tier_file"
        # Fallback to old base.txt if it exists
        local base_list="$debloat_dir/base.txt"
        if [[ -f "$base_list" ]]; then
            log_info "Falling back to base.txt"
            mapfile -t base_packages < <(load_debloat_list "$base_list")
            all_packages+=("${base_packages[@]}")
        fi
    fi

    # Step 3: Load vendor-specific list based on detected device
    local vendor
    vendor=$(get_vendor_name)

    if [[ -n "$vendor" ]]; then
        local vendor_file="$debloat_dir/vendor/${vendor}.txt"
        if [[ -f "$vendor_file" ]]; then
            log_info "Loading vendor list: $vendor"
            mapfile -t vendor_packages < <(load_debloat_list "$vendor_file")
            all_packages+=("${vendor_packages[@]}")
        fi
    fi

    # Step 4: Load Google list if degoogle flag set
    if [[ "$degoogle" == "1" ]]; then
        local google_list="$debloat_dir/google.txt"
        if [[ -f "$google_list" ]]; then
            log_info "Loading Google apps list (degoogle mode)"
            mapfile -t google_packages < <(load_debloat_list "$google_list")
            all_packages+=("${google_packages[@]}")
        fi
    fi

    # Step 5: Remove duplicates
    mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | sort -u)

    if [[ ${#all_packages[@]} -eq 0 ]]; then
        log_warning "No packages to debloat"
        log_info "Add packages to debloat-lists/tiers/*.txt files"
        return 0
    fi

    log_info ""
    log_info "Total packages to process: ${#all_packages[@]}"

    if is_dry_run; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    if ! is_dry_run && [[ "${FORCE:-0}" != "1" ]]; then
        if ! confirm "Proceed with debloat?"; then
            log_info "Debloat cancelled"
            return 0
        fi
    fi

    # Step 6: Debloat
    debloat_packages "${all_packages[@]}"

    log_section "Debloat Complete"
    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    phase_debloat
fi
