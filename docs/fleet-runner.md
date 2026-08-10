# Fleet Runner — unattended OTA updates (Phase 1)

Keep a fleet of Android devices updated with **zero ongoing involvement**: a host
(your NAS/server) reaches every device over wireless ADB on a schedule and
re-applies its desired state — **config drift-correction + app installs/upgrades** —
then reports OS status.

This is **Phase 1**: host-side push over wireless ADB, no device-side agent, works
today on **unrooted** devices. See [Phase 2](#phase-2--the-robust-end-state) for the
scale/robustness end-state (Device Owner + self-hosted Headwind MDM), which is the
only unrooted path to *automated OS OTA*.

## What it does each run

For every enabled device in the inventory:

1. **Reconnect** over wireless ADB, with retries and an optional mDNS fallback.
2. **`config`** — re-apply the device's profile (reverts any drift, e.g. someone
   re-enabled the lock screen). Silent, idempotent.
3. **`apps`** — install/upgrade the device's app set. `adb install -r` is silent;
   `fdroid:` sources auto-resolve the latest version, so apps actually update.
4. **OS status** — report the running Android/patch level. On unrooted devices it
   **cannot** auto-install an OTA and says so plainly (Phase 2 fixes this).

Failure is isolated per device — one offline tablet never aborts the run. Each step
runs as its own `provision.sh` subprocess. A run ends with a summary and a non-zero
exit if any device was unreachable or errored (so the timer/journal flags it).

## One-time onboarding (per device)

Because the devices are unrooted, do this **once** per device over USB:

1. Enable Developer Options + USB debugging.
2. Plug into the **runner host** (the box that will run the schedule) and run:
   ```bash
   ./provision.sh setup-agent --wireless
   ```
   On the device, when the RSA prompt appears, tick **"Always allow from this
   computer"** and accept. That authorization persists across reboots, so headless
   runs never need a tap again. (On a *rooted* device `setup-agent` pre-plants the
   key automatically; unrooted uses this always-allow.)
3. Give the device a **static IP / DHCP reservation** and note `ip:5555`.
4. Add a row to the inventory (below).

> **Reboot caveat (unrooted):** plain `adb tcpip 5555` does **not** survive a reboot,
> and Android 11+ Wireless-debugging randomizes the connect port. Mitigations:
> keep kiosks powered (they rarely reboot); set an `mdns` name in the inventory as a
> fallback; or re-run `setup-agent --wireless` over USB after a reboot. This
> fragility is the reason Phase 2 inverts the connection (device dials out).

## Inventory

Copy the template and edit:

```bash
cp fleet/inventory.conf.example fleet/inventory.conf
```

`fleet/inventory.conf` is git-ignored (keeps your IPs private). One device per line:

```
# name        target              profile  app_set  debloat  degoogle  enabled  [mdns]
m11-wall      192.168.1.60:5555   m11      none     none     0         1
m9-wall       192.168.1.61:5555   m9       minimal  none     0         1
```

Columns are documented in `fleet/inventory.conf.example`. Notes:
- `app_set = none` skips app updates; point it at an app set to enable them.
- Prefer app sets built from `fdroid:` entries — those auto-update. A `url:` source
  caches by filename and will **not** re-pull a newer build at the same URL.
- `debloat` day-2 default is `none` (debloat is an onboarding step, not a recurring one).

## Run it

```bash
# Preview every device's steps — makes NO changes:
./provision.sh fleet --dry-run

# Real run:
./provision.sh fleet

# Custom inventory:
./provision.sh fleet --inventory /path/to/other.conf
```

## Schedule it (systemd --user)

```bash
mkdir -p ~/.config/systemd/user
cp fleet/systemd/android-fleet.{service,timer} ~/.config/systemd/user/
# Edit ExecStart in the .service if your checkout path differs.
systemctl --user daemon-reload
systemctl --user enable --now android-fleet.timer

# Verify / operate:
systemctl --user list-timers android-fleet.timer
systemctl --user start android-fleet.service   # run once now
journalctl --user -u android-fleet.service -e   # read the last run's log
```

To let it run while you're logged out: `loginctl enable-linger $USER`.

## Phase 2 — the robust end-state

Phase 1 is great while devices stay reachable on the LAN, but can't do automated OS
updates and needs the host to reach each device. **Phase 2** inverts the model to
match the giganticplayground `fleet-platform` (devices *pull*, server never pushes):

- One-time `adb shell dpm set-device-owner` at onboarding (no root, no accounts on device).
- A self-hosted **Headwind MDM** agent as the Device Owner app → silent app
  install/update, kiosk lock-task, remote config, and — via `SystemUpdatePolicy`
  (`TYPE_INSTALL_AUTOMATIC`) — **automated OS OTA in a maintenance window**.
- Control plane self-hosted on home-k3s behind Cloudflare; NAT/reboot/IP-immune.

android-suite then becomes the **onboarding/provisioning layer** (debloat +
set-device-owner + enroll); day-2 config/app/OS updates move to Headwind. The Phase-1
runner remains the fallback lane for any device that can't be a Device Owner.
