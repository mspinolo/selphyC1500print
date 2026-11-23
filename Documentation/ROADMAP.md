# Project roadmap

This document is the working plan for `selphyC1500print`. Keep it updated as implementation and validation progress. The repository is the source of truth for project status; conversation history is supplementary.

## Project goal

Build a native macOS utility for preparing JPEG files for the Canon SELPHY CP1500 using the Farbenwerk CP1500 ICC profile, with a transparent, testable color workflow and safe handling of originals.

The project is experimental until the conversion workflow has been independently verified and compared against physical prints. Direct print submission must remain disabled until that validation is complete.

## Current status

The README describes the following as implemented in source:

- SwiftUI macOS application and persistent user preferences.
- ICC profile structural validation.
- ColorSync-based conversion from the embedded source RGB profile (or assumed sRGB) through the profile connection space to the Farbenwerk CP1500 profile.
- Rendering-intent and black-point-compensation preferences.
- Export to temporary JPEG copies tagged as sRGB after conversion.
- EXIF orientation handling and read-only treatment of source files.
- Automated tests, including ICC parsing, malformed-profile cases, ColorSync conversion, and numerical comparison with LittleCMS.
- GitHub Actions CI intended to run tests with the Farbenwerk profile supplied ephemerally.

**Important:** these are implementation claims, not a declaration that the project has passed a clean build, CI, numerical acceptance thresholds, or physical-print validation. Verify each item before marking it validated.

## Current validation findings (2026-11-24)

Latest verified CI: GitHub Actions run [45289743953](https://github.com/mspinolo/selphyC1500print/actions/runs/45289743953) (build 72), commit `51f358f`.

- Swift package compilation succeeded and the Farbenwerk profile download succeeded.
- Automated tests: 18 executed, 13 passed, 5 failed. All five failures are assertions in `testColorSyncMatchesIndependentLittleCMSReference`; the other 13 tests passed.
- Relative-colorimetric, BPC off: mean raw RGB error 0.594, P95 1, max 3.
- Relative-colorimetric, BPC on: mean 8.823, P95 27, max 39. Worst sample: input `[230, 180, 217]`, ColorSync channel value 248 versus LittleCMS 209.
- Perceptual: max raw RGB error 11 for both BPC off and on, exceeding the unchanged limit of 10 by one level.
- The standard LittleCMS transform's BPC on/off probe changed 81 of 96 output bytes.
- Controlled `cmsCreateExtendedTransform` probes establish the observed mapping for the two-profile chain (sRGB/source profile → printer profile): `[true, false]` matches standard `cmsCreateTransform` with BPC disabled; `[false, true]` and `[true, true]` match standard BPC enabled. Thus the second array entry is the effective BPC entry for this chain. Preserve this as an experimentally verified regression assertion; do not infer it from parameter names alone.
- ColorSync sequence-placement diagnostics do not reproduce LittleCMS equivalently: no BPC is close to LittleCMS without BPC (mean 0.594, P95 1, max 3), while source-only, destination-only, and both placements remain materially different. In particular, the current production configuration enables BPC on both ColorSync sequence entries, and its relative-colorimetric output does not match the LittleCMS standard BPC oracle. This is an unresolved cross-CMM semantic difference, not evidence that either engine is necessarily wrong.

**Production status:** no change to `ColorCorrectionService.swift` or the printing workflow is authorized while this discrepancy is under investigation. Test thresholds must remain unchanged.

## Roadmap

### 1. Repository and build audit

- [ ] Review the source tree, package/project configuration, test targets, and CI workflows.
- [ ] Build on a supported macOS/Xcode environment.
- [ ] Run the complete test suite from a clean checkout.
- [ ] Run the GitHub Actions workflow and resolve failures. Latest run 45289743953 builds successfully but has 5 numerical comparison failures; see Current validation findings.
- [ ] Record the tested macOS, Xcode, and Swift versions.
- [ ] Confirm that no proprietary ICC profile, personal photo, or generated print output is committed unintentionally.

**Exit criteria:** clean build and repeatable test run; CI is green, or any remaining environment limitation is explicitly documented.

### 2. ICC color-management review

- [ ] Review the ColorSync transform construction and source/destination profile handling.
- [ ] Confirm the exact semantics of the Farbenwerk CP1500 profile and the intended pre-correction workflow.
- [ ] Verify all supported rendering intents: perceptual, relative colorimetric, and saturation.
- [ ] Verify black-point compensation behavior where supported; document any ColorSync/API limitation rather than assuming equivalence with LittleCMS. LittleCMS two-profile probe confirms that BPC array entry 1 (the printer-profile entry) reproduces standard cmsCreateTransform BPC; ColorSync placement equivalence remains unresolved.
- [ ] Review assumptions for untagged JPEGs, embedded RGB profiles, grayscale images, unsupported color spaces, and malformed profiles.
- [ ] Verify alpha handling, bit depth, orientation, metadata preservation, and JPEG quality settings.
- [ ] Document why converted RGB values are tagged sRGB for the printer's fixed internal color pipeline, and the limitations of this experimental approach.

**Exit criteria:** documented color pipeline, explicit handling of unsupported inputs, and numerical tests with justified tolerances.

### 3. Automated test strategy

- [ ] Keep deterministic synthetic fixtures for neutral ramps, RGB/CMY primaries, intermediate colors, and skin-tone-like patches.
- [ ] Test ICC parsing, invalid/truncated profiles, missing profiles, and unsupported image formats.
- [ ] Test each rendering intent and black-point-compensation combination.
- [ ] Compare ColorSync results with an independent LittleCMS oracle only where transform semantics are demonstrated to be comparable. Keep BPC-on comparisons diagnostic until ColorSync's sequence-entry semantics are established.
- [ ] Define numeric tolerances and report differences in a meaningful color space (preferably ΔE in Lab/ΔE00, where the test setup permits).
- [ ] Verify output dimensions, JPEG decodability, output profile tag, EXIF orientation, and source-file byte-for-byte immutability.
- [ ] Test failure paths, temporary-file cleanup, and stale-session cleanup.
- [ ] Add regression fixtures for every defect discovered.

**Exit criteria:** tests are deterministic, meaningful, and pass in CI. A passing software test suite is not proof of print accuracy.

### 4. CI and developer workflow

- [ ] Confirm the macOS GitHub Actions runner and supported toolchain.
- [ ] Ensure the licensed Farbenwerk ICC profile is fetched only at runtime and is not committed, logged, or uploaded as an artifact.
- [ ] Ensure CI fails clearly when the profile download or validation fails.
- [ ] Run build, unit tests, and integration tests on pull requests.
- [ ] Document local test setup and required environment variables in the README.

**Exit criteria:** a clean checkout can be validated locally and by CI using documented steps.

### 5. Application workflow and usability

- [ ] Review image import, preview, profile selection, rendering-intent selection, and export behavior.
- [ ] Make the distinction between original, converted preview, and exported file unmistakable.
- [ ] Provide clear errors for missing/invalid profiles and unsupported images.
- [ ] Confirm temporary-file lifecycle and user-visible export location.
- [ ] Keep direct printing disabled until the print-validation gate is passed.

**Exit criteria:** a user can safely select an image, understand the chosen conversion, and export a converted copy without risking the original.

### 6. Physical validation on the Canon SELPHY CP1500

- [ ] Prepare matched uncorrected and corrected test images using the same print settings and media.
- [ ] Print the 10 × 15 cm synthetic chart in `Tests/Fixtures/CP1500-ICC-Test-10x15.svg` (or a rasterized equivalent with controlled color values).
- [ ] Add a separate natural-skin-tone photograph as a qualitative visual reference when available.
- [ ] Compare neutral balance, skin tones, saturated colors, shadow detail, and highlight detail under consistent viewing conditions.
- [ ] If possible, measure printed patches with a suitable instrument and record measurement conditions.
- [ ] Record printer settings, media, driver options, date, and observations in a validation report.
- [ ] Decide whether the pre-correction workflow improves the intended output; revise the model if it does not.

**Exit criteria:** repeatable physical-print evidence supports the workflow. Visual inspection of a single print is useful but not a colorimetric certification.

### 7. Printing and release readiness

- [ ] Only after physical validation, design and implement direct print submission.
- [ ] Test printer discovery, job submission, cancellation, errors, and completion handling.
- [ ] Ensure temporary files are retained until the print system has consumed them, then cleaned safely.
- [ ] Add user documentation, limitations, and a release checklist.
- [ ] Keep the application clearly labeled experimental until the release criteria are met.

**Exit criteria:** reliable end-to-end workflow, documented limitations, passing CI, and successful repeatable print tests.

## Test assets

- `Tests/Fixtures/CP1500-ICC-Test-10x15.svg`: synthetic 10 × 15 cm diagnostic chart. It is not a certified color target.
- Natural-skin-tone photograph: to be added manually under `Tests/Fixtures/`. Treat it as a qualitative visual reference, not a calibrated measurement target.
- Farbenwerk CP1500 ICC profile: user-supplied/licensed project asset currently kept at repository root by explicit user decision. Do not move or remove it; do not reopen this repository-placement decision. Avoid copying it into CI artifacts or logs.

## Working rules

1. Do not overwrite or modify user source images.
2. Do not claim color accuracy based only on a successful build or a passing software test.
3. Keep personal photographs and generated print outputs out of public commits unless explicitly cleared. The Farbenwerk ICC profile at repository root is an explicit user-authorized exception; preserve its current location.
4. Update this roadmap when a task is completed, deferred, or blocked; distinguish **implemented**, **tested**, and **validated by physical print**.
5. Prefer small, reviewable commits and keep the README consistent with actual behavior.
