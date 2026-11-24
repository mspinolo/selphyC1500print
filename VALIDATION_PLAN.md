# SELPHY CP1500 color workflow validation plan

This document separates software correctness from actual printer-color accuracy. Passing unit tests is necessary, but it is not evidence that the pre-correction model improves physical prints.

## 1. Automated software checks

Portable core (Linux or macOS), no dependencies beyond a C compiler and CMake:

```sh
cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure
```

Whole application on macOS with the project toolchain:

```sh
swift test
```

The macOS CI workflow runs the real-profile integration tests against the profile committed at the repository root. To run the same tests locally:

```sh
SELPHY_TEST_PRINTER_PROFILE="/absolute/path/ICC-Profile165-CP1500.icc" swift test
```

The profile lives only at the repository root (owner decision); do not copy it into test fixtures or upload it as a CI artifact.

The suite currently checks:

- ICC header size, signature, class, RGB device space and Lab PCS.
- ICC tag-table bounds and paired A2B/B2A intent availability.
- Rejection of malformed ICC data.
- Real-profile conversion for perceptual, relative-colorimetric and saturation intents, each with BPC off and on (core tests and macOS integration tests).
- Closed-loop check against the printer profile's own forward model (A2B): the corrected values must reproduce the intended Lab of neutral steps and skin tones within DeltaE2000 limits, never be worse than sending the values uncorrected, and at least halve the chart's mean deviation. Optimised and exact LittleCMS pipelines must agree to well below 1 DeltaE2000.
- Output JPEG decoding, RGB color model, sRGB tag, dimensions and source-file byte-for-byte preservation.
- Failure behavior for an invalid printer profile.

## 2. Additional software test matrix before enabling printing

The following cases should be added or manually exercised as the implementation evolves:

| Area | Test input | Expected result |
|---|---|---|
| Source profile | Embedded sRGB | Convert from embedded sRGB |
| Source profile | Embedded Adobe RGB (1998) | Convert from Adobe RGB, not assume sRGB |
| Source profile | No embedded profile | Explicit sRGB fallback; report this assumption |
| Source profile | Grayscale or CMYK JPEG | Clear unsupported-format error; no partial output |
| Image geometry | EXIF orientations 1, 3, 6 and 8 | Output pixels have visually correct orientation |
| Image geometry | Portrait and landscape | Dimensions/orientation preserved |
| File safety | Read-only source file | Conversion succeeds where access permits; source unchanged |
| File safety | Several inputs, one invalid input | Fail atomically and remove the partial session |
| File safety | Two same-named files in different folders | Unique output names; no overwrite |
| ICC handling | Missing/corrupt/incompatible profile | Clear error, no output files |
| Colour core | Each intent and BPC state | Successful transform; intents give distinct output; BPC follows the ICC rules (forced for v4 perceptual/saturation) |
| Output | Re-open generated JPEG | Decodable RGB JPEG with embedded sRGB profile |
| Temporary files | Conversion failure | Partial output folder removed |
| Temporary files | Old abandoned session | Removed only on next conversion, according to retention policy |

The current integration test is a first end-to-end smoke test, not yet the complete matrix above. In particular, the test must eventually cover embedded Adobe RGB, missing-profile fallback, EXIF orientation, grayscale/CMYK rejection, multiple inputs, and atomic cleanup.

## 3. Validate the transform direction and numeric behavior

The conversion engine is LittleCMS (vendored). Earlier work compared it with ColorSync on raw RGB codes; that comparison is retired because ColorSync ignores BPC on the destination entry and applies it on the source entry with semantics that match neither LittleCMS setting (see the findings in `Documentation/ROADMAP.md`). Accuracy is now judged in DeltaE2000 through the printer profile's own A2B model: the predicted Lab of the corrected values against the intended Lab of the source. Tolerances live next to the tests (`Tests/CoreTests/core_tests.c`) with their justification.

The Farbenwerk file is a printer-class RGB/Lab profile with A2B and B2A tables for three intents. The intended compensation path is:

1. Decode source RGB using its embedded source profile (or explicitly assumed sRGB).
2. Convert source RGB to the ICC PCS.
3. Use the printer profile's PCS-to-device (B2A) path to obtain compensated RGB values.
4. Encode those numeric values in a JPEG tagged sRGB for the SELPHY's normal input path.

This is a deliberate pre-compensation strategy for the printer's fixed internal pipeline, not the usual workflow of sending a printer-profile-tagged file to a fully color-managed printer driver. It is only valid if the printer's internal processing and the driver path behave as assumed.

For a stronger numerical validation, use a known RGB test chart and independently calculate expected PCS and B2A values with a second ICC engine (for example a second CMM such as ColorSync, used only as a cross-check). Compare in DeltaE2000 within a documented tolerance, never in raw code values alone.

Also verify that:
- the selected intent is applied to both the source-to-PCS and PCS-to-device legs;
- BPC is passed only where supported and its effect is measured;
- the pixel buffer's byte order, channel order, row stride and alpha-skip layout are correct;
- the JPEG output's embedded profile describes the output numbers as sRGB;
- no second application-side conversion or driver-side color adjustment is unintentionally applied.

## 4. Controlled physical print experiment

Do not start with ordinary photographs alone. First use a reproducible chart containing:

- neutral gray ramp from near-black to near-white;
- near-black and shadow-detail patches;
- skin-tone patches;
- saturated red, green, blue, cyan, magenta and yellow;
- moderate and low-saturation colors;
- a smooth gradient to reveal banding or clipping.

Use a second chart with photographic content (portrait/skin, foliage, sky, neutral objects and deep shadows) after the patch test.

For every chart, prepare:
- A: original, uncorrected JPEG;
- B: pre-corrected JPEG.

Print A and B through the exact same macOS/SELPHY path, on Canon RP-108 paper, with identical driver/printer settings. Disable automatic photo enhancement or scene correction wherever the driver or printer exposes such controls. Do not change any setting between A and B. Randomize print order and make at least three repeats of each condition to expose print-to-print variation.

Record:
- macOS version, app build/commit, printer firmware if available;
- USB or Wi-Fi connection and exact print application/driver path;
- paper and consumable pack;
- all printer/driver enhancement settings;
- rendering intent and BPC;
- print order and repeat number.

Allow prints to stabilize under identical conditions before visual or instrumental comparison. View under a consistent, high-quality neutral light source. A spectrophotometer is strongly preferred: measure patch Lab values and calculate Delta E 2000 against the intended reference values. Report mean, median, 95th percentile and maximum Delta E00, plus neutral-axis error and shadow/white clipping. Compare the corrected print both with the uncorrected print and with the intended source appearance.

Do not choose an intent based on one attractive photograph. Select it using the patch chart and repeatability, then confirm with the photographic chart.

## 5. Suggested acceptance gates

These are project gates, not claims about Canon or Farbenwerk specifications:

1. **Build gate:** macOS CI build and all automated tests pass.
2. **Data-integrity gate:** every source file remains byte-identical; no partial output survives failed batches.
3. **Numerical gate:** app output agrees with an independent ICC reference within a tolerance agreed before testing (initial target: mean channel difference <= 1 code value and 99th percentile <= 2 code values for lossless intermediate comparisons; JPEG output needs a separate allowance for compression).
4. **Color gate:** corrected prints show a repeatable improvement in Delta E00 versus uncorrected prints on the same patches, without unacceptable neutral, skin-tone or shadow regressions.
5. **Workflow gate:** the actual macOS print path is documented and does not silently apply a conflicting second color correction.

Until all gates pass, keep direct printing disabled and treat generated JPEGs as experimental proofs only.
