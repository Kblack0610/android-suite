# Android Provisioning Suite - Usage Guide

## Overview

The Android Provisioning Suite uses three independent dimensions that can be mixed and matched:

- **App Sets** - What apps to install (minimal, personal, work, testing)
- **Debloat Levels** - What to remove (light, standard, aggressive + degoogle)
- **Device Configs** - Device-specific settings (pixel, samsung, xiaomi, etc.)

## Quick Start

```bash
# Detect your device
./provision.sh detect

# Full interactive provisioning
./provision.sh provision

# Or run individual commands
./provision.sh apps --set personal
./provision.sh debloat --level standard
./provision.sh config --device samsung
```

## Commands

### Apps - Install Applications

Install apps from predefined app sets with support for local APKs, F-Droid, and URLs.

```bash
# List available app sets
./provision.sh apps --list

# Preview what would be installed
./provision.sh apps --set personal --preview

# Install apps from a set
./provision.sh apps --set personal

# Dry run (preview without installing)
./provision.sh apps --set work --dry-run
```

**Available App Sets:**

| Set | Description |
|-----|-------------|
| `minimal` | Essential utilities only |
| `personal` | Full personal phone setup |
| `work` | Business/productivity apps |
| `testing` | Development and debug tools |

### Debloat - Remove Bloatware

Remove unwanted system apps using a tiered approach.

```bash
# List available tiers
./provision.sh debloat --list

# Standard debloat (keeps Google)
./provision.sh debloat --level standard

# Aggressive debloat
./provision.sh debloat --level aggressive

# Aggressive + remove Google services
./provision.sh debloat --level aggressive --degoogle

# Light debloat only
./provision.sh debloat --level light

# Preview what would be removed
./provision.sh debloat --level standard --dry-run
```

**Debloat Tiers (Cumulative):**

| Tier | What it removes |
|------|-----------------|
| `light` | Carrier bloat, print services, unused input methods |
| `standard` | Light + vendor bloat, some Google apps, wellness apps |
| `aggressive` | Standard + more system apps, productivity apps |

**Additional Flags:**

- `--degoogle` - Remove Google services (combinable with any tier)

### Config - Apply Device Settings

Apply device-specific settings and optimizations.

```bash
# Auto-detect device and apply config
./provision.sh config

# Apply Samsung-specific config
./provision.sh config --device samsung

# Apply Pixel config
./provision.sh config --device pixel

# Preview changes
./provision.sh config --device xiaomi --dry-run
```

**Device Configs:**

| Config | Target Devices |
|--------|----------------|
| `pixel` | Google Pixel (clean AOSP) |
| `samsung` | Samsung Galaxy (OneUI) |
| `xiaomi` | Xiaomi, Redmi, POCO (MIUI/HyperOS) |
| `oneplus` | OnePlus, OPPO, Realme (OxygenOS/ColorOS) |
| `default` | Universal settings |

### Detect - Show Device Info

Display information about the connected device.

```bash
./provision.sh detect
```

### Provision - Full Interactive Setup

Run the complete provisioning workflow with interactive prompts.

```bash
# Interactive mode
./provision.sh provision

# Force mode (skip prompts, use defaults)
./provision.sh provision --force

# Skip root extras
./provision.sh provision --skip-root
```

## Global Options

| Option | Description |
|--------|-------------|
| `-d, --dry-run` | Preview without making changes |
| `-f, --force` | Skip confirmation prompts |
| `-l, --list-devices` | List connected ADB devices |
| `-h, --help` | Show help message |
| `-v, --version` | Show version |

## Creating Custom App Sets

Create a new file in `app-sets/` with `.txt` extension:

```txt
# app-sets/custom.txt
# My custom app set

@include base.txt

# Local APKs (from apks/ directory)
local:myapp.apk

# F-Droid packages (auto-download)
fdroid:org.mozilla.firefox
fdroid:com.termux

# Direct URL
url:https://example.com/app.apk
```

**Manifest Format:**

| Prefix | Description | Example |
|--------|-------------|---------|
| `local:` | APK from apks/ directory | `local:signal.apk` |
| `fdroid:` | F-Droid package ID | `fdroid:org.mozilla.firefox` |
| `url:` | Direct download URL | `url:https://...` |
| `@include` | Include another set | `@include base.txt` |

## Customizing Debloat Lists

### Adding Packages to Tiers

Edit files in `debloat-lists/tiers/`:

```txt
# debloat-lists/tiers/light.txt
com.example.bloatware

# Use @include for cumulative behavior
@include light.txt  # in standard.txt
```

### Adding Vendor-Specific Packages

Edit files in `debloat-lists/vendor/`:

```txt
# debloat-lists/vendor/samsung.txt
com.samsung.android.bixby.agent
```

### Adding Google Packages

Edit `debloat-lists/google.txt` (used with `--degoogle` flag).

## Examples

### Personal Phone Setup

```bash
# Full setup for a personal Samsung phone
./provision.sh provision

# Or manually:
./provision.sh debloat --level standard
./provision.sh apps --set personal
./provision.sh config --device samsung
```

### Work Phone (Minimal, Keep Google)

```bash
./provision.sh debloat --level light
./provision.sh apps --set work
./provision.sh config --device pixel
```

### Privacy-Focused Phone (DeGoogled)

```bash
./provision.sh debloat --level aggressive --degoogle
./provision.sh apps --set minimal
./provision.sh config --device default
```

### Testing/Development Device

```bash
./provision.sh debloat --level light
./provision.sh apps --set testing
```

## Directory Structure

```
android-suite/
├── provision.sh          # Main entry point
├── app-sets/             # App set manifests
│   ├── base.txt
│   ├── minimal.txt
│   ├── personal.txt
│   ├── work.txt
│   └── testing.txt
├── debloat-lists/
│   ├── tiers/            # Cumulative debloat tiers
│   │   ├── light.txt
│   │   ├── standard.txt
│   │   └── aggressive.txt
│   ├── vendor/           # Device-specific bloat
│   │   ├── samsung.txt
│   │   ├── xiaomi.txt
│   │   └── oneplus.txt
│   └── google.txt        # Google apps (--degoogle)
├── profiles/             # Device settings configs
├── phases/               # Provisioning phases
├── tools/                # Helper scripts
├── apks/                 # Local APK files (gitignored)
└── downloads/            # Downloaded APKs (gitignored)
```

## Troubleshooting

### No Device Detected

```bash
# Check ADB connection
adb devices

# Ensure USB debugging is enabled on device
# Settings > Developer Options > USB Debugging
```

### F-Droid Downloads Failing

- Requires `curl` and `jq` installed
- Check internet connection
- F-Droid index may be temporarily unavailable

### Package Removal Failing

- Some packages are protected system apps
- Try with `adb root` if device is rooted
- Check if package exists: `adb shell pm list packages | grep <name>`
