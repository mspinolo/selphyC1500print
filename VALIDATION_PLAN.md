# SELPHY CP1500 color workflow validation plan

This document separates software correctness from actual printer-color accuracy. Passing unit tests is necessary, but it is not evidence that the pre-correction model improves physical prints.

## 1. Automated software checks

Install the test-only LittleCMS dependency first, then run on macOS with the project toolchain:

```sh
brew install little-cms2 pkgconf
```



```sh
swift test
```

The macOS CI workflow downloads the licensed Farbenwerk profile into its ephemeral runner and executes the real-profile integration tests without committing or uploading the profile. To run the same tests locally, make the profile available:

```sh
SELPHY_TEST_PRINTER_PROFILE="/absolute/path/ICC-Profile165-CP1500.icc" swift test
```

The profile must not be committed, uploaded as a CI artifact, or copied into test fixtures. The CI download is used only during the ephemeral job.

The suite currently checks:

- ICC header size, signature, class, RGB device space and Lab PCS.
- ICC tag-table bounds and paired A2B/B2A intent availability.
- Rejection of malformed ICC data.
- Real-profile ColorSync conversion for perceptual, relative-colorimetric and saturation intents, each with BPC off and on.
- Numerical comparison against an independent LittleCMS transform for a 32-patch sRGB chart, across all three intents and both BPC states. The current comparison samples patch centers to reduce JPEG edge artifacts.
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
| ColorSync | Each intent and BPC state | Successful transform; distinct settings actually reach ColorSync |
| Output | Re-open generated JPEG | Decodable RGB JPEG with embedded sRGB profile |
| Temporary files | Conversion failure | Partial output folder removed |
| Temporary files | Old abandoned session | Removed only on next conversion, according to retention policy |

The current integration test is a first end-to-end smoke test, not yet the complete matrix above. In particular, the test must eventually cover embedded Adobe RGB, missing-profile fallback, EXIF orientation, grayscale/CMYK rejection, multiple inputs, and atomic cleanup.

## 3. Validate the transform direction and numeric behavior

A LittleCMS test oracle is now included. It independently transforms the sampled sRGB chart pixels through the same printer profile and compares those expected device RGB values with decoded pixels from the ColorSync-generated JPEG. This checks transform direction, intent selection, BPC propagation and channel/buffer handling. The current acceptance tolerance is mean absolute channel difference <= 3 code values and maximum <= 10 code values at patch centers. If this comparison fails, do not widen the tolerance without first investigating profile intent handling, BPC semantics, pixel formats and JPEG encoding.

The Farbenwerk file is a printer-class RGB/Lab profile with A2B and B2A tables for three intents. The intended compensation path is:

1. Decode source RGB using its embedded source profile (or explicitly assumed sRGB).
2. Convert source RGB to the ICC PCS.
3. Use the printer profile's PCS-to-device (B2A) path to obtain compensated RGB values.
4. Encode those numeric values in a JPEG tagged sRGB for the SELPHY's normal input path.

This is a deliberate pre-compensation strategy for the printer's fixed internal pipeline, not the usual workflow of sending a printer-profile-tagged file to a fully color-managed printer driver. It is only valid if the printer's internal processing and the driver path behave as assumed.

For a stronger numerical validation, use a known RGB test chart and independently calculate expected PCS and B2A values with a second ICC engine (for example LittleCMS used only as a test oracle, not as the app's production engine). Compare the app's output pixel values to that independent reference within a documented tolerance. Do not use the app's own ColorSync code as its only oracle.

Also verify that:
- the selected intent is applied to both the source-to-PCS and PCS-to-device legs as intended by ColorSync;
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
- B: ColorSync-pre-corrected JPEG.

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
