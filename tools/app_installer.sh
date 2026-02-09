#!/usr/bin/env bash
# App Installer - Parses app-set manifests and installs APKs
# Supports: local files, F-Droid packages, direct URLs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(dirname "$SCRIPT_DIR")"
APP_SETS_DIR="$SUITE_DIR/app-sets"
APKS_DIR="$SUITE_DIR/apks"
DOWNLOAD_DIR="$SUITE_DIR/downloads"

# Source base functions if available
[[ -f "$SUITE_DIR/base_functions.sh" ]] && source "$SUITE_DIR/base_functions.sh"

# F-Droid API
FDROID_REPO="https://f-droid.org/repo"
FDROID_INDEX="https://f-droid.org/repo/index-v2.json"

# Parsed packages storage
declare -a PARSED_PACKAGES=()
declare -A PARSED_SOURCES=()  # package -> source type
declare -A PARSED_VALUES=()   # package -> value (filename/package_id/url)

# ============================================================================
# Manifest Parsing
# ============================================================================

parse_manifest() {
    local manifest_file="$1"
    local already_included="${2:-}"

    if [[ ! -f "$manifest_file" ]]; then
        log_error "Manifest not found: $manifest_file"
        return 1
    fi

    # Prevent circular includes
    if [[ "$already_included" == *"$manifest_file"* ]]; then
        log_warning "Circular include detected: $manifest_file"
        return 0
    fi
    already_included="${already_included}:${manifest_file}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Handle @include directive
        if [[ "$line" =~ ^@include[[:space:]]+(.+)$ ]]; then
            local include_file="${BASH_REMATCH[1]}"
            local include_path

            # Resolve relative to current manifest directory
            if [[ "$include_file" != /* ]]; then
                include_path="$APP_SETS_DIR/$include_file"
            else
                include_path="$include_file"
            fi

            parse_manifest "$include_path" "$already_included"
            continue
        fi

        # Parse source:value format
        if [[ "$line" =~ ^(local|fdroid|url):(.+)$ ]]; then
            local source_type="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            local key

            case "$source_type" in
                local)
                    key="local:$value"
                    ;;
                fdroid)
                    key="fdroid:$value"
                    ;;
                url)
                    key="url:$value"
                    ;;
            esac

            # Avoid duplicates
            if [[ ! " ${PARSED_PACKAGES[*]} " =~ " ${key} " ]]; then
                PARSED_PACKAGES+=("$key")
                PARSED_SOURCES["$key"]="$source_type"
                PARSED_VALUES["$key"]="$value"
            fi
        fi
    done < "$manifest_file"
}

# ============================================================================
# F-Droid Support
# ============================================================================

download_fdroid_apk() {
    local package_id="$1"
    local output_dir="${2:-$DOWNLOAD_DIR}"

    mkdir -p "$output_dir"

    log_info "Fetching F-Droid info for: $package_id"

    # Use F-Droid API to get latest APK URL
    # Simple approach: construct URL directly (works for most packages)
    # Format: https://f-droid.org/repo/{package_id}_{versioncode}.apk

    # First try to get package info from index
    local apk_name
    local apk_url

    # Try direct download of latest suggested version
    # F-Droid format: packagename_versioncode.apk
    # We'll use a simpler approach - download the index and parse

    local index_file="$output_dir/.fdroid_index.json"

    # Cache index for 1 hour
    if [[ ! -f "$index_file" ]] || [[ $(find "$index_file" -mmin +60 2>/dev/null) ]]; then
        log_info "Downloading F-Droid index..."
        if ! curl -sL -o "$index_file" "$FDROID_INDEX"; then
            log_error "Failed to download F-Droid index"
            return 1
        fi
    fi

    # Parse index for package info (using jq if available, else fallback)
    if command -v jq &>/dev/null; then
        local pkg_info
        pkg_info=$(jq -r --arg pkg "$package_id" '.packages[$pkg].versions | to_entries | .[0].value | "\(.file.name) \(.manifest.versionCode)"' "$index_file" 2>/dev/null)

        if [[ -n "$pkg_info" && "$pkg_info" != "null null" ]]; then
            apk_name="${pkg_info%% *}"
            apk_url="$FDROID_REPO/$apk_name"
        fi
    fi

    # Fallback: try common URL pattern
    if [[ -z "$apk_url" ]]; then
        log_warning "Could not find $package_id in F-Droid index, trying direct download"
        # This won't work for most packages but worth a try
        apk_url="$FDROID_REPO/${package_id}.apk"
        apk_name="${package_id}.apk"
    fi

    local output_file="$output_dir/$apk_name"

    if [[ -f "$output_file" ]]; then
        log_info "APK already downloaded: $apk_name"
        echo "$output_file"
        return 0
    fi

    log_info "Downloading: $apk_url"
    if curl -sL -o "$output_file" "$apk_url"; then
        # Verify it's actually an APK
        if file "$output_file" | grep -q "Android\|Zip archive"; then
            log_success "Downloaded: $apk_name"
            echo "$output_file"
            return 0
        else
            log_error "Downloaded file is not a valid APK"
            rm -f "$output_file"
            return 1
        fi
    else
        log_error "Failed to download: $apk_url"
        return 1
    fi
}

# ============================================================================
# URL Download Support
# ============================================================================

download_url_apk() {
    local url="$1"
    local output_dir="${2:-$DOWNLOAD_DIR}"

    mkdir -p "$output_dir"

    # Extract filename from URL
    local filename="${url##*/}"
    filename="${filename%%\?*}"  # Remove query string

    # Ensure .apk extension
    [[ "$filename" != *.apk ]] && filename="${filename}.apk"

    local output_file="$output_dir/$filename"

    if [[ -f "$output_file" ]]; then
        log_info "APK already downloaded: $filename"
        echo "$output_file"
        return 0
    fi

    log_info "Downloading: $url"
    if curl -sL -o "$output_file" "$url"; then
        if file "$output_file" | grep -q "Android\|Zip archive"; then
            log_success "Downloaded: $filename"
            echo "$output_file"
            return 0
        else
            log_error "Downloaded file is not a valid APK"
            rm -f "$output_file"
            return 1
        fi
    else
        log_error "Failed to download: $url"
        return 1
    fi
}

# ============================================================================
# Installation
# ============================================================================

install_from_manifest() {
    local app_set="$1"
    local manifest_file="$APP_SETS_DIR/${app_set}.txt"

    if [[ ! -f "$manifest_file" ]]; then
        log_error "App set not found: $app_set"
        log_info "Available sets: $(ls -1 "$APP_SETS_DIR"/*.txt 2>/dev/null | xargs -n1 basename | sed 's/.txt$//' | tr '\n' ' ')"
        return 1
    fi

    log_info "Loading app set: $app_set"

    # Clear previous parse
    PARSED_PACKAGES=()
    PARSED_SOURCES=()
    PARSED_VALUES=()

    # Parse the manifest
    parse_manifest "$manifest_file"

    if [[ ${#PARSED_PACKAGES[@]} -eq 0 ]]; then
        log_warning "No packages found in app set: $app_set"
        return 0
    fi

    log_info "Found ${#PARSED_PACKAGES[@]} packages to install"

    local installed=0
    local failed=0

    for key in "${PARSED_PACKAGES[@]}"; do
        local source_type="${PARSED_SOURCES[$key]}"
        local value="${PARSED_VALUES[$key]}"
        local apk_path=""

        case "$source_type" in
            local)
                apk_path="$APKS_DIR/$value"
                if [[ ! -f "$apk_path" ]]; then
                    log_error "Local APK not found: $value"
                    ((failed++))
                    continue
                fi
                ;;
            fdroid)
                if [[ "${DRY_RUN:-0}" == "1" ]]; then
                    log_info "[DRY-RUN] Would download from F-Droid: $value"
                    continue
                fi
                apk_path=$(download_fdroid_apk "$value") || {
                    log_error "Failed to get F-Droid package: $value"
                    ((failed++))
                    continue
                }
                ;;
            url)
                if [[ "${DRY_RUN:-0}" == "1" ]]; then
                    log_info "[DRY-RUN] Would download from URL: $value"
                    continue
                fi
                apk_path=$(download_url_apk "$value") || {
                    log_error "Failed to download: $value"
                    ((failed++))
                    continue
                }
                ;;
        esac

        if [[ -n "$apk_path" ]]; then
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                log_info "[DRY-RUN] Would install: $apk_path"
            else
                if install_apk "$apk_path"; then
                    ((installed++))
                else
                    ((failed++))
                fi
            fi
        fi
    done

    log_info "Installation complete: $installed succeeded, $failed failed"
    return 0
}

# List available app sets
list_app_sets() {
    log_info "Available app sets:"
    for set_file in "$APP_SETS_DIR"/*.txt; do
        [[ -f "$set_file" ]] || continue
        local set_name
        set_name=$(basename "$set_file" .txt)
        local desc
        desc=$(head -n2 "$set_file" | grep "^#" | head -n1 | sed 's/^#\s*//')
        printf "  %-15s %s\n" "$set_name" "$desc"
    done
}

# Preview what would be installed
preview_app_set() {
    local app_set="$1"
    local manifest_file="$APP_SETS_DIR/${app_set}.txt"

    if [[ ! -f "$manifest_file" ]]; then
        log_error "App set not found: $app_set"
        return 1
    fi

    PARSED_PACKAGES=()
    PARSED_SOURCES=()
    PARSED_VALUES=()

    parse_manifest "$manifest_file"

    log_info "App set '$app_set' contains ${#PARSED_PACKAGES[@]} packages:"
    for key in "${PARSED_PACKAGES[@]}"; do
        local source_type="${PARSED_SOURCES[$key]}"
        local value="${PARSED_VALUES[$key]}"
        printf "  [%-6s] %s\n" "$source_type" "$value"
    done
}

# ============================================================================
# Fallback logging functions (if base_functions.sh not loaded)
# ============================================================================

if ! declare -f log_info &>/dev/null; then
    log_info()    { echo "[INFO] $*"; }
    log_success() { echo "[OK] $*"; }
    log_warning() { echo "[WARN] $*"; }
    log_error()   { echo "[ERROR] $*" >&2; }
fi

if ! declare -f install_apk &>/dev/null; then
    install_apk() {
        local apk_path="$1"
        log_info "Installing: $(basename "$apk_path")"
        adb_cmd install -r "$apk_path"
    }
fi

if ! declare -f adb_cmd &>/dev/null; then
    adb_cmd() {
        if [[ -n "${DEVICE_SERIAL:-}" ]]; then
            adb -s "$DEVICE_SERIAL" "$@"
        else
            adb "$@"
        fi
    }
fi

# ============================================================================
# CLI
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        list)
            list_app_sets
            ;;
        preview)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 preview <set-name>"; exit 1; }
            preview_app_set "$2"
            ;;
        install)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 install <set-name>"; exit 1; }
            install_from_manifest "$2"
            ;;
        *)
            echo "Usage: $0 {list|preview|install} [set-name]"
            echo ""
            echo "Commands:"
            echo "  list              List available app sets"
            echo "  preview <set>     Preview packages in an app set"
            echo "  install <set>     Install apps from an app set"
            exit 1
            ;;
    esac
fi
