# SELPHY CP1500 Print

A native macOS utility for experimental pre-correction of images (JPEG, JPEG XL, PNG, TIFF) for the Canon SELPHY CP1500. The colour conversion runs in a portable, tested C core built on LittleCMS (vendored, MIT).

> **Status: experimental.** The pre-correction is implemented, builds and is exercised by CI. The colour model is trusted on the vendor's (Farbenwerk's) documentation and has **not** been validated with physical prints. Direct printing remains disabled. Plan and evidence levels: `Documentation/ROADMAP.md`.

## Current milestone

- Native SwiftUI macOS interface.
- Persistent printer name, rendering intent, BPC preference and security-scoped ICC bookmark.
- Structural ICC validation.
- LittleCMS transform (16-bit internally) from the source image's embedded RGB profile (or assumed sRGB when absent) through PCS to the Farbenwerk printer profile's RGB device values. Black point compensation follows the ICC rules: always applied for perceptual/saturation with a v4 profile, optional for relative colorimetric.
- Temporary copies in PNG (default, lossless: no lossy codec after the correction) or, optionally, JPEG (quality 0.98, smaller files). Sources are decoded at 16 bits per component; transparent areas are composited on white. Output is the corrected numeric RGB values tagged as sRGB for the SELPHY's fixed internal color pipeline.
- EXIF orientation is applied when decoding; source files are read-only.
- Temporary sessions are stored under the system temporary directory and abandoned sessions older than 24 hours are removed on the next conversion.

## Color workflow: important caveat

Farbenwerk describes the CP1500 profile as a way to pre-adjust the image file to better match the printer's fixed internal color management. The app therefore uses the printer profile as the destination of a ColorSync conversion, then writes the resulting RGB numbers with an sRGB tag so the normal SELPHY path can interpret them.

This is an experimental compensation workflow, not a conventional fully color-managed print pipeline. The output must be compared with uncorrected prints before enabling production use. The app does not yet submit print jobs.

## Automated validation

Two suites, both using the Farbenwerk profile from the repository root:

```sh
# Portable colour core (Linux or macOS): seconds, no macOS APIs
cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure

# Whole application (macOS)
SELPHY_TEST_PRINTER_PROFILE="$PWD/ICC-Profile165-CP1500.icc" swift test
```

The core tests check error handling (truncated/garbage/wrong-class profiles), BPC semantics, that the optimised transform matches the exact pipeline (DeltaE2000), that the printer's own forward model reproduces the intended appearance for neutrals and skin tones, tone-curve monotonicity, 8-bit/16-bit consistency and honouring of wide-gamut source profiles. The macOS suite covers ICC inspection, buffer handling, PNG output (dimensions, sRGB tag), source immutability, batch failure cleanup and end-to-end appearance.

These checks establish that the software does what the colour model says. They do **not** establish that the model produces more accurate physical prints; that is the optional track P in the roadmap.

## Build

Requires macOS 14 or later and Xcode/Swift 5.9 or later. No Homebrew packages are needed: LittleCMS is vendored in `Sources/CLittleCMS`.

```sh
swift build
swift run
```

## Next steps

The plan, milestones and evidence levels are maintained in [`Documentation/ROADMAP.md`](Documentation/ROADMAP.md). Physical print comparison is an optional, non-blocking track there.

## Privacy

- Preview: a model-based soft proof shows the original, the expected print without correction and with correction (slider), computed from the printer profile's forward model and the display's ColorSync profile. It is a simulation, not a print proof, and has not been validated with physical prints.
- Saving: the generated copies are temporary (removed after 24 hours); "Salva in una cartella..." copies them to a folder you choose. Files already there are never overwritten or deleted (a number is added to the name), and the source photos are never touched.
- The preview keeps its decoded and corrected data in memory, so changing a display option or going back to a photo is fast.
- Source images are never modified.
- The app does not embed the ICC profile: the user selects it at runtime. A copy is kept at the repository root for tests.
- Temporary copies are stored outside the photo library.
