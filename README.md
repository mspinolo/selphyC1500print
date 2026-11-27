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
- The save folder is remembered between launches. A running conversion shows progress and can be cancelled (no files are left behind).
- App bundle: `scripts/make-app.sh` builds a sandboxed, ad-hoc signed `.app` (CI publishes it as an artifact); see `Documentation/RELEASE.md`.
- The preview keeps its decoded and corrected data in memory, so changing a display option or going back to a photo is fast.
- Source images are never modified.
- The app does not embed the ICC profile: the user selects it at runtime. A copy is kept at the repository root for tests.
- Temporary copies are stored outside the photo library.

## Language
The interface is in English by default; choose "Italiano" in the language picker at the top right of the window (the choice is remembered).

## Download and first launch
Pre-releases are on the GitHub Releases page (zip + SHA-256). The app is ad-hoc signed and **not notarised**: after unzipping, open it with right-click → Open (or `xattr -dr com.apple.quarantine "SELPHY CP1500 Print.app"`). Versions `0.0.x` are pre-releases; `1.0.0` will only be published when the checklist in `Documentation/RELEASE.md` is complete.

## Physical validation
The procedure for validating the corrections with real prints (test chart, scanner-based measurement, report and acceptance gates) is in `Documentation/PHYSICAL_VALIDATION.md`; the tools are in `validation/` and are self-tested in CI with synthetic scans.
