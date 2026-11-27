# SELPHY CP1500 Print

A native macOS utility for experimental pre-correction of images (JPEG, JPEG XL, PNG, TIFF) for the Canon SELPHY CP1500. The colour conversion runs in a portable, tested C core built on LittleCMS (vendored, MIT).

> **Status: experimental pre-release.** The pre-correction, the soft-proof preview, the analysis tools and printing through the macOS print dialog are implemented and exercised by CI. The colour model is trusted on the vendor's (Farbenwerk's) documentation and has **not** yet been validated with physical prints: the app's *Print validation assistant* (menu Advanced) is the way to do it. Plan and evidence levels: `Documentation/ROADMAP.md`.

**How to use it: [`Documentation/USER_GUIDE.md`](Documentation/USER_GUIDE.md).**

## Features

- Pre-correction through the Farbenwerk profile with LittleCMS (16-bit internally), from the photo's embedded profile (sRGB when absent); BPC per the ICC rules. PNG (default, lossless) or JPEG output, tagged sRGB.
- Soft-proof preview (original, without/with correction, compare, ΔE map, dark zones, out of gamut, postcard layout) and a full-screen view at full resolution on a neutral grey.
- Statistics window: ΔE00 statistics and histogram, ΔE00 distribution scope (image width/height, lightness, hue), a*-b* gamut plot, intent comparison, CSV/PDF export.
- Printing through the macOS print dialog (AirPrint).
- Print validation assistant: test chart, blind print order, scanner check on a ColorChecker (all editions; default: Classic before November 2014), automatic analysis of the chart scans, gates and report.
- English and Italian; light, dark and neutral grey themes.
- Inputs: JPEG, JPEG XL, PNG, TIFF (8/16 bit, any embedded RGB profile, greyscale/CMYK converted); EXIF orientation applied; originals never modified.

## Color workflow: important caveat

Farbenwerk describes the CP1500 profile as a way to pre-adjust the image file to better match the printer's fixed internal color management. The app therefore uses the printer profile as the destination of a ColorSync conversion, then writes the resulting RGB numbers with an sRGB tag so the normal SELPHY path can interpret them.

This is an experimental compensation workflow, not a conventional fully color-managed print pipeline. The corrected copies can be printed from the app through the macOS print dialog (AirPrint; switch the printer's Image Optimize off), but until they have been compared with uncorrected prints the results are a model-based expectation, not a verified outcome.

## Automated validation

Three suites, all using the Farbenwerk profile from the repository root:

```sh
# Portable colour core (Linux or macOS): seconds, no macOS APIs
cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure

# Physical-validation tools, and the app's chart-scan analysis (C core) against them
SELPHY_CORE_LIB="$PWD/build/libselphy_core_shared.so" python3 -m unittest discover -s validation/tests   # .dylib on macOS

# Whole application (macOS)
SELPHY_TEST_PRINTER_PROFILE="$PWD/ICC-Profile165-CP1500.icc" swift test
```

The core tests check error handling (truncated/garbage/wrong-class profiles), BPC semantics, that the optimised transform matches the exact pipeline (DeltaE2000), that the printer's own forward model reproduces the intended appearance for neutrals and skin tones, tone-curve monotonicity, 8-bit/16-bit consistency and honouring of wide-gamut source profiles. The macOS suite covers ICC inspection, buffer handling, PNG output (dimensions, sRGB tag), source immutability, batch failure cleanup, end-to-end appearance, 16-bit / linear / Display P3 inputs, the preview and full-screen pipelines, the statistics, the validation assistant (chart identical to the Python one, analysis of synthetic scans, report) and window snapshots. The Python suite checks the validation tools on synthetic scans and that the app's C implementation finds the same corner marks and samples.

These checks establish that the software does what the colour model says. They do **not** establish that the model produces more accurate physical prints; that is the optional track P in the roadmap.

## Build

Requirements:

- **macOS 27.0 or later** to run the app. The target minimum is macOS 27.2; it will be raised as soon as the GitHub macOS runner image runs 27.2, so that the macOS tests can still run in CI (the workflow posts a notice when that happens).
- **Xcode 27.2** (Swift 6.4 toolchain, macOS 27.2 SDK) to build. The package uses `swift-tools-version: 6.4` and the **Swift 6 language mode**, so data races are checked at compile time.
- No Homebrew packages: LittleCMS is vendored in `Sources/CLittleCMS`.

```sh
swift build
swift run
swift test              # macOS suite
scripts/make-app.sh     # sandboxed, ad-hoc signed .app (see Documentation/RELEASE.md)
```

The portable colour core also builds and tests on Linux with CMake (see Tests above).

## Next steps

The plan, milestones and evidence levels are maintained in [`Documentation/ROADMAP.md`](Documentation/ROADMAP.md). Physical print comparison is an optional, non-blocking track there.

## Files and privacy

- Source images are never modified; the app only reads them.
- **Temporary copies**: "Generate corrected copies" writes the corrected files to a session folder, by default in the system temporary folder. In **Settings > Temporary copies** you can choose another folder (for example on a larger disk): the app then uses a subfolder named "SELPHY CP1500 Print temporary" inside it. Sessions older than 24 hours are removed when new copies are made; only the app's own session folders in that subfolder are removed, never anything else.
- **Saving**: "Save to a folder…" copies the corrected files to a folder you choose. Files already there are never overwritten or deleted (a number is added to the name). The save folder is remembered between launches.
- A running conversion shows progress and can be cancelled (no files are left behind).
- The preview is a model-based soft proof computed from the printer profile's forward model and the display's ColorSync profile: a simulation, not a print proof. It keeps its decoded and corrected data in memory, so changing a display option or going back to a photo is fast.
- The app does not embed the ICC profile: you select it at runtime (a copy is kept at the repository root for the tests). Profiles, folders and photos are remembered with sandbox security-scoped bookmarks.
- The print validation assistant keeps its session (choices, results, notes) in the app's Application Support folder; scans and photos stay where you keep them.
- Nothing is sent over the network.
- App bundle: `scripts/make-app.sh` builds a sandboxed, ad-hoc signed `.app` (CI publishes it as an artifact); see `Documentation/RELEASE.md`.

## Language
The interface is in English by default; choose "Italiano" in **Settings > General > Language** (the choice is remembered). The same section has the interface theme, including a neutral grey for judging colours.

## Download and first launch
Pre-releases are on the GitHub Releases page (zip + SHA-256). The app is ad-hoc signed and **not notarised**: after unzipping, open it with right-click → Open (or `xattr -dr com.apple.quarantine "SELPHY CP1500 Print.app"`). Versions `0.0.x` are pre-releases; `1.0.0` will only be published when the checklist in `Documentation/RELEASE.md` is complete.

## Physical validation
The procedure for validating the corrections with real prints (test chart, scanner-based measurement, report and acceptance gates) is in `Documentation/PHYSICAL_VALIDATION.md`. The app guides you through it (**Advanced > Print validation assistant**); the reference tools are in `validation/`, with the ColorChecker reference values of every edition in `validation/references/`, and are self-tested in CI with synthetic scans.
