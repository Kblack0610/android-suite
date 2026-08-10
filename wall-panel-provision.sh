#!/usr/bin/env bash
# wall-panel-provision.sh - ONE command to turn a Headwind-enrolled Lenovo tablet
# into a finished FreeKiosk Home Assistant wall panel.
#
# Chains the whole flow that was done by hand for the first two tablets:
#   detect -> debloat(aggressive) -> FreeKiosk install+config -> OS kiosk tuning
#   -> runtime grants -> set-as-home -> disable lock screen -> wireless ADB.
#
# One-time HUMAN prereqs (ADB can't bootstrap these):
#   1. Headwind device-owner enrolled: factory reset -> tap 6-7x on the FIRST
#      setup screen -> scan the Headwind QR -> SKIP the Google account.
#   2. Developer options -> USB debugging ON; plug in USB; tap "Allow" (RSA).
#
# Still manual AFTER (printed at the end):
#   - HA login once in FreeKiosk (session persists via keep-me-logged-in).
#   - Wireless Debugging pairing for reboot-proof ADB (needs the on-screen code).
#
# Usage:
#   wall-panel-provision.sh --serial SERIAL --name wall-<room> [--device m11|m9]
#                           [--url URL] [--pin PIN] [--dry-run]
set -euo pipefail

SUITE="$HOME/.dotfiles/.local/src/android-suite"
FK_PROVISION="$HOME/dev/home/home-config/scripts/provision-wall-tablet.sh"
FK_APK="$SUITE/apks/freekiosk.apk"

SERIAL="" NAME="" DEVICE="m11" DRY=0
URL="https://hass.kblab.me/wall-panels/home?kiosk"
PIN="4321"

die() { echo "error: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --serial|-S) SERIAL="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --device|-D) DEVICE="$2"; shift 2;;
    --url) URL="$2"; shift 2;;
    --pin) PIN="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done
[ -n "$SERIAL" ] || die "--serial is required (multiple adb devices/emulators may be attached)"
[ -n "$NAME" ]   || die "--name is required (e.g. wall-kitchen)"
[ -f "$FK_APK" ] || die "FreeKiosk APK missing at $FK_APK (curl the release from github.com/RushB-fr/freekiosk)"
command -v adb >/dev/null || die "adb not found"

A() { if [ "$DRY" = 1 ]; then echo "  adb -s $SERIAL $*"; else adb -s "$SERIAL" "$@"; fi; }
step() { echo; echo "==> $*"; }

MODEL="$(adb -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo '?')"
OWNER="$(adb -s "$SERIAL" shell dpm list-owners 2>/dev/null | tr -d '\r' | grep -c hmdm || true)"
echo "==> Wall-panel provision: $NAME  ($MODEL, serial $SERIAL, profile $DEVICE)"
[ "$OWNER" -ge 1 ] 2>/dev/null || echo "    WARNING: Headwind device-owner not detected - enroll via QR first (see --help)."

REST_KEY="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
# Persist the REST key: FreeKiosk's key is SET-ONCE (it can't be changed via ADB
# intent after initial setup, and there's no endpoint to reset it), so a lost key
# permanently locks you out of the /api/js + /api/url control channel on :8080.
# Recovery path = this file. (Learned the hard way 2026-07-16.)
KEY_DIR="$HOME/.config/wall-tablets"; KEY_FILE="$KEY_DIR/${NAME}.rest-key"
if [ "$DRY" != 1 ]; then
  mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"
  { printf 'name=%s\nserial=%s\nmodel=%s\npin=%s\nrest_key=%s\nport=8080\n' \
      "$NAME" "$SERIAL" "$MODEL" "$PIN" "$REST_KEY"; } > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "    REST key + PIN saved to $KEY_FILE (mode 600)"
fi

step "1/7 Debloat (aggressive)"
( cd "$SUITE" && ./provision.sh debloat --level aggressive -S "$SERIAL" --force $([ "$DRY" = 1 ] && echo --dry-run) )

step "2/7 FreeKiosk install + config (URL/PIN/kiosk/auto-boot/REST)"
"$FK_PROVISION" --serial "$SERIAL" --name "$NAME" --apk "$FK_APK" \
  --url "$URL" --pin "$PIN" --rest-key "$REST_KEY" $([ "$DRY" = 1 ] && echo --dry-run)

step "3/7 OS kiosk tuning (profile $DEVICE)"
( cd "$SUITE" && ./provision.sh config --device "$DEVICE" -S "$SERIAL" --force $([ "$DRY" = 1 ] && echo --dry-run) )

step "4/7 Runtime grants (prevents the first-boot permission dialog)"
for p in POST_NOTIFICATIONS CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION; do
  A shell pm grant com.freekiosk "android.permission.$p" || true
done
A shell appops set com.freekiosk SYSTEM_ALERT_WINDOW allow || true

step "5/7 Set FreeKiosk as home launcher"
A shell cmd package set-home-activity com.freekiosk/.MainActivity || true

step "6/7 Disable lock screen (wall panel never locks)"
A shell locksettings set-disabled true || true

step "7/7 Flip to wireless ADB (unplug after this)"
if [ "$DRY" = 1 ]; then echo "  adb -s $SERIAL tcpip 5555 ; adb connect <ip>:5555"; else
  IP="$(adb -s "$SERIAL" shell ip route 2>/dev/null | awk '/wlan0/ {print $9; exit}' | tr -d '\r')"
  adb -s "$SERIAL" tcpip 5555 >/dev/null 2>&1 || true; sleep 2
  [ -n "$IP" ] && adb connect "$IP:5555" 2>&1 | tail -1
  echo "  wireless serial: ${IP:-<unknown>}:5555"
fi

cat <<EOF

==> Scripted provisioning done for '$NAME' ($MODEL).
    REST key: $REST_KEY  (also saved: ${KEY_FILE:-<dry-run>})
    Control channel: curl -H "X-Api-Key: \$REST_KEY" http://<ip>:8080/api/status
                     POST /api/js {"code":"..."} + /api/url {"url":"..."} (PIN=$PIN)

Finish ON THE TABLET (not ADB-scriptable):
  1. HA login: log in once in FreeKiosk (keep-me-logged-in persists it).
  2. Wireless Debugging (reboot-proof ADB): Settings > Developer options >
     Wireless debugging > "Pair device with pairing code" -> run:
       adb pair <ip>:<pair-port> <6-digit-code>
     (the tcpip:5555 link above works now but DROPS ON REBOOT - persist.adb.tcp.port
     is empty; without this pairing a reboot needs USB to get wireless adb back.)
  3. Change the PIN from '$PIN' if you want (FreeKiosk settings, or --pin next time).
  4. VOICE (Binks satellite): assign the browser in HA's Voice Satellite panel, then
     verify the mic. getUserMedia FAIL modes: NotAllowedError = permission (rare,
     FreeKiosk auto-grants once RECORD_AUDIO exists); NotReadableError "could not
     start audio source" = the mic source won't open - reboot to clear a stuck audio
     HAL, and test the mic natively (com.zui.recorder) to rule out hardware.

Headwind manages it OTA from here (fleet: android_<device> in gatus).
EOF
