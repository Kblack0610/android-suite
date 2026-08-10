# Kiosk wall panels — Lenovo Tab M11 / M9

Provisions a stock-Android Lenovo Tab M11 or M9 into an always-on Home Assistant
wall panel running **FreeKiosk** (`github.com/RushB-fr/freekiosk`).

**Source of truth for the whole feature** (hardware, dashboard, screensaver, network,
FreeKiosk app config): `~/dev/home/home-config/docs/wall-panels.md`. This file only
covers the `android-suite` side — the OS-level tablet prep that used to be manual.

## One-shot per tablet

```bash
cd ~/.dotfiles/.local/src/android-suite
./provision.sh -l                                        # find the tablet's serial

# 1. Strip to near-stock (barebones kiosk)
./provision.sh debloat --level aggressive -S <serial>    # + auto-loads the lenovo vendor list

# 2. Apply the always-on wall-panel OS tuning
./provision.sh config  --device m11 -S <serial>          # or: --device m9
```

Preview either step first with `--dry-run` (no device writes).

`./provision.sh detect -S <serial>` auto-suggests `m11`/`m9` from the model code
(`ro.product.model`), and `debloat`/`config` without `--device` will pick it up.

## Over-the-network (OTA) provisioning — no cable

A wall-mounted tablet is awkward to reach with USB, so provision it over Wi-Fi. ADB is
transport-agnostic: once the tablet shows up as `<ip>:<port>` in `adb devices`, **every
command above works unchanged** — just pass that as the `-S` serial.

**Fully cable-free (Android 11+ Wireless debugging — the M11/M9 both have it):**
```bash
# On the tablet: Settings > Developer options > Wireless debugging > ON.
#   Tap "Pair device with pairing code" → note the ip:PORT and the 6-digit code.
#   The main Wireless-debugging screen shows a DIFFERENT ip:PORT — that's the connect target.
./provision.sh connect --pair 192.168.1.60:37115 --code 481502 --ip 192.168.1.60:43001
#   → pairs, connects, and prints the device + "Suggested profile: m11"

./provision.sh debloat --level aggressive -S 192.168.1.60:43001 --dry-run
./provision.sh config  --device m11        -S 192.168.1.60:43001
```

**One-cable bootstrap (plug in once, then unplug):**
```bash
./provision.sh connect --from-usb     # flips the USB device to TCP/IP + connects; then unplug
```

**Already in TCP/IP or wireless-debugging mode:**
```bash
./provision.sh connect --ip 192.168.1.60:5555
```

> **Reboot caveat:** these tablets aren't rooted, so the wireless link drops on reboot
> (`--persistent` needs root). The *pairing* persists — after a reboot just re-run
> `connect --ip <host:newport>` with the new port shown on the Wireless-debugging screen.
> For ad-hoc network-ADB outside this suite, use the **`adb-ops` skill**.

## What the `m11` / `m9` config automates (ADB)

| Setting | Value | Why |
|---|---|---|
| `global stay_on_while_plugged_in` | `7` (AC+USB+wireless) | Screen never sleeps on the charger |
| `system screen_off_timeout` | `1800000` | Backstop timeout cap |
| lock screen | disabled (`locksettings set-disabled true`) | No PIN prompt on wake |
| doze | off | A wall panel must stay responsive |
| `global wifi_sleep_policy` | `2` (best-effort) | Wi-Fi stays up (no-op on newer Android) |
| FreeKiosk `RECORD_AUDIO` | granted | Dashboard mic / Binks voice satellite |
| FreeKiosk battery optimization | whitelisted | Kiosk app never killed |
| dark mode | on | Dashboard-friendly |

The FreeKiosk package is **auto-detected** (`pm list packages | grep -i kiosk`); override
with `KIOSK_PACKAGE="…"` in the profile if detection misses.

## What stays manual (not ADB-settable)

- **FreeKiosk app**: start URL `https://hass.kblab.me/wall-panels/home?kiosk&BrowserID=wall-<room>`,
  set-as-Home / launch-on-boot, and **change the default exit PIN `1234`**.
- **Battery longevity (24/7 on charger)**:
  - **M11** — enable Settings → Battery → *Battery Protection* (native charge cap).
  - **M9** — no native cap; gate the charger 20–80% with a smart plug + HA automations.
- **Device-owner lock-task** (strongest kiosk) — needs a factory-fresh device; skipped
  by design. FreeKiosk's home-app + immersive settings already give a solid kiosk.

## Verify

```bash
adb -s <serial> shell settings get global stay_on_while_plugged_in   # 7
adb -s <serial> shell settings get system screen_off_timeout         # 1800000
adb -s <serial> shell locksettings get-disabled                      # true
adb -s <serial> shell dumpsys package <freekiosk-pkg> | grep -A2 RECORD_AUDIO   # granted=true
adb -s <serial> shell dumpsys deviceidle whitelist | grep -i kiosk   # present
```

End-to-end: reboot on the charger → screen stays on, no lock prompt, FreeKiosk loads the
dashboard, and "ok nabu" reaches the mic.
