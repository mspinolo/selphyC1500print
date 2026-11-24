# SELPHY CP1500 Print

A native macOS utility for experimental pre-correction of JPEGs for the Canon SELPHY CP1500.

> **Status: experimental.** ColorSync pre-correction is implemented, builds and is exercised by CI. The colour model is trusted on the vendor's (Farbenwerk's) documentation and has **not** been validated with physical prints. Known open issue: ColorSync's perceptual and black-point-compensation behaviour differs from LittleCMS (see `Documentation/ROADMAP.md`). Direct printing remains disabled.

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

The suite covers ICC header/tag-table parsing, malformed profiles, end-to-end ColorSync conversion, and a numerical comparison of ColorSync output against an independent LittleCMS transform over a 32-patch sRGB chart. CI installs LittleCMS only as a test oracle; the app itself continues to use native ColorSync. The Farbenwerk profile is kept at the repository root (owner decision) and the macOS CI runs the real-profile integration tests against that copy. To run the same tests locally:

```sh
brew install little-cms2 pkgconf
SELPHY_TEST_PRINTER_PROFILE="/path/to/ICC-Profile165-CP1500.icc" swift test
```

The integration test exercises all three supported rendering intents with BPC both off and on, checks that output JPEGs decode at the expected dimensions and are tagged sRGB, and verifies that source bytes remain unchanged.

These automated checks do **not** establish that the pre-correction model produces more accurate physical prints. That requires a controlled print comparison and, ideally, measured patches from the CP1500.

## Build

Requires macOS 14 or later and Xcode/Swift 5.9 or later.

```sh
swift build
swift run
```

## Next steps

The plan, milestones and evidence levels are maintained in [`Documentation/ROADMAP.md`](Documentation/ROADMAP.md). Physical print comparison is an optional, non-blocking track there.

## Privacy

- Source JPEGs are never modified.
- The app does not embed the ICC profile: the user selects it at runtime. A copy is kept at the repository root for tests.
- Temporary JPEGs are stored outside the photo library.
