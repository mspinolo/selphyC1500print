# SELPHY CP1500 Print

A native macOS utility for preparing JPEG copies for a Canon SELPHY CP1500.

> **Status: early development.** The current milestone adds persistent color-management preferences and structural ICC validation. No conversion or print job has yet been validated on a Mac with the actual printer.

## Current milestone

- Native SwiftUI macOS interface.
- Persistent printer name, rendering intent, BPC preference and security-scoped ICC bookmark.
- Structural validation of the selected ICC file (header, declared size, tag-table bounds, device class, color space, PCS and A2B/B2A table pairs).
- JPEG selection without modifying source files.

## Color-management findings

The supplied Farbenwerk profile has been inspected independently: ICC 4.3, class `prtr`, RGB device space, Lab PCS, and A2B/B2A tables for perceptual, media-relative colorimetric and saturation intents.

The profile is a printer profile. The intended pre-adjustment workflow still needs to be confirmed with test prints and the exact Canon/macOS driver path. The app therefore does not yet convert images or submit print jobs. In particular, it must not silently apply a second color conversion after pre-adjustment.

## Planned next steps

1. Implement the ColorSync transform with explicit source profile, Farbenwerk profile, rendering intent and BPC.
2. Define and verify the output tagging expected by the Canon print queue.
3. Create disposable print copies and validate color handling through USB.
4. Add printer discovery and robust print-job lifecycle/cleanup.
5. Verify Wi-Fi printing using the same macOS print pipeline.

## Build

Requires macOS 14 or later and Xcode/Swift 5.9 or later.

```sh
swift build
swift run
```

## Privacy and files

- Source JPEGs are read-only; all processing will target temporary copies.
- ICC profiles are selected by the user and are not bundled as application resources.
- Temporary print files will be created outside the photo library and removed after use.
