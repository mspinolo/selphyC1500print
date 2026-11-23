# SELPHY CP1500 Print

A native macOS utility for experimental pre-correction of JPEGs for the Canon SELPHY CP1500.

> **Status: experimental.** ColorSync pre-correction is implemented in source, but it has not yet been compiled or validated with physical prints. Direct printing remains disabled.

## Current milestone

- Native SwiftUI macOS interface.
- Persistent printer name, rendering intent, BPC preference and security-scoped ICC bookmark.
- Structural ICC validation.
- ColorSync transform from the source JPEG's embedded RGB profile (or assumed sRGB when absent) through PCS to the Farbenwerk printer profile's RGB device values.
- Temporary JPEG copies, with the corrected numeric RGB values tagged as sRGB for the SELPHY's fixed internal color pipeline.
- EXIF orientation is applied when decoding; source files are read-only.
- Temporary sessions are stored under the system temporary directory and abandoned sessions older than 24 hours are removed on the next conversion.

## Color workflow: important caveat

Farbenwerk describes the CP1500 profile as a way to pre-adjust the image file to better match the printer's fixed internal color management. The app therefore uses the printer profile as the destination of a ColorSync conversion, then writes the resulting RGB numbers with an sRGB tag so the normal SELPHY path can interpret them.

This is an experimental compensation workflow, not a conventional fully color-managed print pipeline. The output must be compared with uncorrected prints before enabling production use. The app does not yet submit print jobs.

## Automated validation

Run the automated suite on macOS:

```sh
swift test
```

The suite covers ICC header/tag-table parsing, malformed profiles, end-to-end ColorSync conversion, and a numerical comparison of ColorSync output against an independent LittleCMS transform over a 32-patch sRGB chart. CI installs LittleCMS only as a test oracle; the app itself continues to use native ColorSync. The macOS CI downloads the licensed Farbenwerk profile into the ephemeral runner's temporary directory and runs the real-profile integration tests; the profile is not committed or uploaded as an artifact. To run the same tests locally, make the profile available:

```sh
brew install little-cms2 pkgconf
SELPHY_TEST_PRINTER_PROFILE="/path/to/ICC-Profile165-CP1500.icc" swift test
```

The integration test exercises all three supported rendering intents with BPC both off and on, checks that output JPEGs decode at the expected dimensions and are tagged sRGB, and verifies that source bytes remain unchanged. The profile is deliberately not committed to the public repository or uploaded as a CI artifact.

These automated checks do **not** establish that the pre-correction model produces more accurate physical prints. That requires a controlled print comparison and, ideally, measured patches from the CP1500.

## Build

Requires macOS 14 or later and Xcode/Swift 5.9 or later.

```sh
swift build
swift run
```

## Next validation steps

1. Compile and fix any SDK/Swift bridging issues on the target macOS.
2. Generate test copies using the supplied ICC profile.
3. Print matched uncorrected/corrected samples through the same CP1500 path.
4. Compare skin tones, neutral grays, saturated colors and shadow detail.
5. Only after validation, implement print submission and temporary-file cleanup after job completion.

## Privacy

- Source JPEGs are never modified.
- The proprietary ICC profile is selected by the user and is not bundled in this repository.
- Temporary JPEGs are stored outside the photo library.
