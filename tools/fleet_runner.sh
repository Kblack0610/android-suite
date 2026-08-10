#!/usr/bin/env bash
# Fleet Runner — Phase 1 host-side scheduled updater
# Reads a device inventory, reaches each device over wireless ADB, and re-applies
# its desired state (config drift-correction + app installs/upgrades), unattended.
#
# Design notes:
#   * Failure isolation is mandatory. Every per-device action runs as an isolated
#     `provision.sh` subprocess and is guarded by an `if`, so one offline or
#     failing tablet never aborts the fleet run (despite `set -euo pipefail`).
#   * All heavy lifting reuses existing commands (config/apps/debloat). This file
#     only adds: inventory parsing, a retrying reconnect, and a run summary.
#   * OS updates are report-only on unrooted devices (see fleet_os_report). True
#     automated OTA is Phase 2 (Device Owner + Headwind MDM).

# Resolve suite dir when sourced (provision.sh sets SUITE_DIR) or run standalone.
if [[ -z "${SUITE_DIR:-}" ]]; then
    SUITE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fi

# Tunables (override via environment)
FLEET_INVENTORY="${FLEET_INVENTORY:-$SUITE_DIR/fleet/inventory.conf}"
FLEET_CONNECT_RETRIES="${FLEET_CONNECT_RETRIES:-3}"
FLEET_CONNECT_DELAY="${FLEET_CONNECT_DELAY:-3}"

# Connect to a device with bounded retries, then an optional mDNS fallback.
# Args: target(host[:port])  mdns_name(optional)
# Echoes the serial to use on success; returns non-zero if unreachable.
fleet_connect() {
    local target="$1"
    local mdns="${2:-}"
    local attempt out

    for attempt in $(seq 1 "$FLEET_CONNECT_RETRIES"); do
        if out=$(adb_connect "$target" 2>/dev/null); then
            echo "$out"
            return 0
        fi
        log_debug "connect attempt $attempt/$FLEET_CONNECT_RETRIES failed for $target"
        sleep "$FLEET_CONNECT_DELAY"
    done

    # mDNS fallback — the connect port can change across reboots on unrooted
    # Wireless-debugging; the mDNS service name is stable.
    if [[ -n "$mdns" && "$mdns" != "-" ]]; then
        log_warning "Static target $target unreachable — trying mDNS: $mdns"
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            echo "$mdns"
            return 0
        fi
        if adb connect "$mdns" 2>/dev/null | grep -qiE "connected to"; then
            log_success "Connected via mDNS: $mdns"
            echo "$mdns"
            return 0
        fi
    fi

    return 1
}

# Best-effort OS status. Honest by design: reports the running OS/patch level and
# states plainly that it did NOT (and cannot, unrooted) apply an OS update.
fleet_os_report() {
    local serial="$1"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[DRY-RUN] Would report OS / security-patch level for $serial"
        return 0
    fi

    local rel patch build
    rel=$(adb -s "$serial" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
    patch=$(adb -s "$serial" shell getprop ro.build.version.security_patch 2>/dev/null | tr -d '\r')
    build=$(adb -s "$serial" shell getprop ro.build.version.incremental 2>/dev/null | tr -d '\r')

    log_info "OS: Android ${rel:-?}  |  security-patch ${patch:-?}  |  build ${build:-?}"
    log_warning "OS auto-update NOT applied — unrooted devices cannot auto-install OTA."
    log_info "  Automated OS OTA needs Phase 2 (Device Owner + Headwind MDM). See docs/fleet-runner.md"
}

# Preview-or-run one step. In dry-run, prints the exact command without executing
# (a fleet dry-run previews the plan; it does not drive per-device logic that needs
# a live device). Otherwise runs the command and returns its status.
# Args: device_name  label  command...
fleet_step() {
    local sname="$1" label="$2"; shift 2
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[$sname] [DRY-RUN] $label: $*"
        return 0
    fi
    log_info "[$sname] $label"
    "$@"
}

# Run the desired-state steps for one already-connected device.
# Args: name serial profile app_set debloat degoogle
# Returns 0 if all steps succeeded, 1 otherwise.
fleet_apply_device() {
    local name="$1" serial="$2" profile="$3" app_set="$4" debloat="$5" degoogle="$6"
    local prov="$SUITE_DIR/provision.sh"
    local failed=0

    # Config drift-correction (always, unless explicitly skipped)
    if [[ -n "$profile" && "$profile" != "none" && "$profile" != "-" ]]; then
        fleet_step "$name" "config (profile '$profile')" \
            "$prov" config --device "$profile" -S "$serial" -f \
            || { log_error "[$name] config step failed"; failed=1; }
    fi

    # App install / upgrade (adb install -r is silent; fdroid: sources auto-latest)
    if [[ -n "$app_set" && "$app_set" != "none" && "$app_set" != "-" ]]; then
        fleet_step "$name" "apps (set '$app_set')" \
            "$prov" apps --set "$app_set" -S "$serial" \
            || { log_error "[$name] apps step failed"; failed=1; }
    fi

    # Debloat (day-2 default is 'none'; re-apply only if the inventory asks)
    if [[ -n "$debloat" && "$debloat" != "none" && "$debloat" != "-" ]]; then
        local dg=() ; [[ "$degoogle" == "1" ]] && dg=(--degoogle)
        fleet_step "$name" "debloat (tier '$debloat')" \
            "$prov" debloat --level "$debloat" "${dg[@]}" -S "$serial" -f \
            || { log_error "[$name] debloat step failed"; failed=1; }
    fi

    # OS status (report-only)
    fleet_os_report "$serial" || true

    return $failed
}

# Main fleet command. Iterates the inventory; never aborts on a single device.
cmd_fleet() {
    log_section "Fleet Update Run"

    if ! check_adb; then
        return 1
    fi

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    if [[ ! -f "$FLEET_INVENTORY" ]]; then
        log_error "Inventory not found: $FLEET_INVENTORY"
        log_info "Create it from the template:"
        log_info "  cp $SUITE_DIR/fleet/inventory.conf.example $SUITE_DIR/fleet/inventory.conf"
        return 1
    fi

    log_info "Inventory: $FLEET_INVENTORY"
    echo "" >&2

    # Results accumulate here; printed as a summary at the end.
    local -a results=()
    local total=0 ok=0 skipped=0 unreachable=0 errored=0

    # Read the inventory on FD 3 so per-device subprocesses (adb, provision.sh)
    # can never swallow inventory lines via stdin.
    local name target profile app_set debloat degoogle enabled mdns
    while read -r name target profile app_set debloat degoogle enabled mdns <&3 || [[ -n "$name" ]]; do
        # Skip blanks and comments
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue

        total=$((total + 1))

        if [[ "$enabled" != "1" ]]; then
            log_info "[$name] disabled — skipping"
            results+=("SKIP       $name ($target)")
            skipped=$((skipped + 1))
            continue
        fi

        log_section "Device: $name  ($target)"

        # Reconnect (retry + mDNS fallback). Isolated: failure just skips device.
        local serial
        if ! serial=$(fleet_connect "$target" "${mdns:-}"); then
            log_error "[$name] unreachable after $FLEET_CONNECT_RETRIES attempts — skipping"
            results+=("UNREACHABLE $name ($target)")
            unreachable=$((unreachable + 1))
            continue
        fi

        # Apply desired state (each step isolated as a subprocess)
        if fleet_apply_device "$name" "$serial" "$profile" "$app_set" "$debloat" "$degoogle"; then
            log_success "[$name] up to date"
            results+=("OK         $name ($target)")
            ok=$((ok + 1))
        else
            log_error "[$name] completed with errors"
            results+=("ERROR      $name ($target)")
            errored=$((errored + 1))
        fi
    done 3< "$FLEET_INVENTORY"

    # Summary
    log_section "Fleet Run Summary"
    local line
    for line in "${results[@]}"; do
        echo "  $line" >&2
    done
    echo "" >&2
    log_info "Total: $total | OK: $ok | Skipped: $skipped | Unreachable: $unreachable | Errors: $errored"

    # Non-zero exit if anything went wrong (so systemd/cron flags the run),
    # but every device was still attempted.
    [[ $((unreachable + errored)) -eq 0 ]]
}

# Standalone CLI: `tools/fleet_runner.sh [--dry-run] [--inventory <file>]`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "$SUITE_DIR/base_functions.sh"
    DRY_RUN="${DRY_RUN:-0}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run) DRY_RUN=1; shift ;;
            --inventory)  FLEET_INVENTORY="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: fleet_runner.sh [--dry-run] [--inventory <file>]"
                exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    export DRY_RUN
    cmd_fleet
fi
