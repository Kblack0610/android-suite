#!/usr/bin/env bash
# Scrcpy Manager - Multi-device screen mirroring
# Usage: scrcpy_manager.sh [command] [args]
#   all     - Launch all connected devices
#   list    - Show connected devices
#   stop    - Kill all scrcpy instances
#   <model> - Launch specific device (e.g., g991, s901)

set -euo pipefail

SUITE_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "${SUITE_DIR}/base_functions.sh" 2>/dev/null || true

# Handle basename aliases (scrcpy-all, scrcpy-stop)
case "$(basename "$0")" in
    scrcpy-all)  set -- "all" "$@" ;;
    scrcpy-stop) set -- "stop" "$@" ;;
esac

cmd_list() {
    echo "Connected devices:"
    adb devices -l 2>/dev/null | grep -w device | while read -r serial _ rest; do
        model=$(echo "$rest" | grep -oP 'model:\K[^ ]+' || echo "unknown")
        short=$(echo "$model" | sed 's/SM_//' | tr '[:upper:]' '[:lower:]')
        printf "  %-12s %-16s %s\n" "$short" "$serial" "$model"
    done
}

cmd_all() {
    # Kill any existing scrcpy instances for a clean start
    local existing_pids
    existing_pids=$(pgrep -x scrcpy 2>/dev/null || true)
    if [[ -n "$existing_pids" ]]; then
        kill $existing_pids 2>/dev/null || true
        sleep 0.3  # Brief pause to let windows close
    fi

    local count=0
    local serials
    serials=$(adb devices 2>/dev/null | grep -w device | grep -v '^emulator-' | cut -f1)

    if [[ -z "$serials" ]]; then
        echo "No devices connected"
        return 1
    fi

    for serial in $serials; do
        model=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "$serial")
        echo "Launching: $model ($serial)"
        # Use setsid to fully detach process from terminal
        setsid scrcpy -s "$serial" --window-title "$model" --max-size 800 >/dev/null 2>&1 &
        ((count++)) || true
        sleep 0.2
    done
    echo "Launched $count device(s)"
}

cmd_stop() {
    # Use pgrep first to check, then kill only actual scrcpy binaries
    local pids
    pids=$(pgrep -x scrcpy 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        echo "Stopped all scrcpy instances"
    else
        echo "No scrcpy running"
    fi
}

cmd_single() {
    local pattern="$1"
    shift

    local match
    match=$(adb devices -l 2>/dev/null | grep -i "$pattern" | head -1)

    if [[ -z "$match" ]]; then
        echo "No device matching '$pattern'"
        echo ""
        cmd_list
        return 1
    fi

    local serial
    serial=$(echo "$match" | cut -f1)
    local model
    model=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "$serial")

    echo "Launching: $model ($serial)"
    scrcpy -s "$serial" --window-title "$model" "$@"
}

cmd_help() {
    cat <<EOF
Scrcpy Manager - Multi-device screen mirroring

Usage: $(basename "$0") [command] [args]

Commands:
  list          Show connected devices with short names
  all           Launch scrcpy for ALL connected devices
  stop          Kill all scrcpy instances
  <pattern>     Launch device matching pattern (model, serial, etc.)

Examples:
  $(basename "$0") list
  $(basename "$0") all
  $(basename "$0") g991              # Launch S21 by model
  $(basename "$0") s901 --record x.mp4  # Record S22
  $(basename "$0") stop

Aliases:
  scrcpy-all   = $(basename "$0") all
  scrcpy-stop  = $(basename "$0") stop
EOF
}

# Main dispatch
case "${1:-list}" in
    all)       cmd_all ;;
    list)      cmd_list ;;
    stop)      cmd_stop ;;
    -h|--help|help) cmd_help ;;
    *)         cmd_single "$@" ;;
esac
