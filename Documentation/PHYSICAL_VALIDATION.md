# Physical validation procedure (Canon SELPHY CP1500)

Goal: find out, with real prints, whether the pre-correction improves the printed colour, which
intent to make the default, and whether the printer's colour management really is out of the way
when it is switched off (the only setting the CP1500 offers).

Evidence level: **scanner-estimated colorimetry** (flatbed scanner + its ICC profile), not a
spectrophotometer. It resolves differences between variants well (same scan chain for all of
them); absolute dE values carry the scanner uncertainty measured in step 2. Photographs are also
judged by eye. This extends section 4 of `VALIDATION_PLAN.md`.

## What the tools measure
- **Digital chart** (`validation/charts/selphy_chart_v1.png`): 24 ColorChecker colours as sRGB
  numbers, a grey ramp, near-black steps, primaries and secondaries (100 % and 50 %), skin tones,
  nature colours, four mid-greys placed in the corners (sheet uniformity), unprinted paper
  reference areas and four corner marks (the large one is top-left) that make the analysis
  independent of how the print is placed, rotated or scaled. No text on the chart.
- **Intended colour** of every patch = its sRGB numbers converted to Lab (D50, relative).
  **Measured colour** = the scan, converted with your scanner profile and expressed relative to
  the printed paper white. Error = CIEDE2000.
- **Physical ColorChecker Classic**: scanned once, compared with the reference Lab of your chart:
  this bounds the scanner-chain error. It is not printed (it is a pigment chart).

## Variants (13 sheets)
All chart sheets use the same chart file; V1, V2 are produced with the app (output PNG, sRGB tag).

| Variant | File printed | Printer colour management | Purpose |
|---|---|---|---|
| V0 | original chart | OFF | baseline: what the printer does alone |
| V1 | chart corrected, Perceptual | OFF | main result |
| V2 | chart corrected, Relative colorimetric, BPC off | OFF | intent choice |
| V3 | same file as V1 | **ON** | does the printer convert again? |
| V4 | same file as V0 | **ON** | control for V3 |

Plus 4 photographs (portrait, foliage/sky, low-key, black-and-white), each as original (OFF) and
corrected Perceptual (OFF): 8 sheets. Total 13. The black-and-white photo settles the open
question on neutral rendering.

## Before print day
1. **Tools.** Python 3 with `numpy pillow scipy tifffile`; build the colour core library once:
   `cmake -S . -B build && cmake --build build --target selphy_core_shared`
   (macOS: `brew install cmake`). Without cmake:
   `cc -O2 -shared -fPIC -DHasTHREADS=1 -DHAVE_GMTIME_R=1 -ISources/SELPHYColorCore/include -ISources/CLittleCMS/include -ISources/CLittleCMS/src Sources/SELPHYColorCore/selphy_color_core.c Sources/CLittleCMS/src/*.c -lm -o build/libselphy_core_shared.dylib` (after `mkdir -p build`)
   (tested on Linux only). Check the tools: `python3 -m unittest discover -s validation/tests`.
2. **Scanner chain check.** Scan the ColorChecker Classic with exactly the settings you will use
   for the prints. Get the reference Lab (D50) of *your* chart (datasheet, X-Rite software or
   BabelColor; values differ before/after 2014): fill `validation/colorchecker_reference_template.csv`.
   Read, in any image viewer, the pixel coordinates of the centres of dark skin (top-left),
   bluish green (top-right), white (bottom-left), black (bottom-right), chart upright, then:
   `python3 validation/check_scanner.py cc.tif --corners "x,y x,y x,y x,y" --reference my_reference.csv --out results`
   Mean dE00 of a few units is normal for a flatbed; above about 5, suspect that the profile is applied twice
   or not at all (see scanning).
3. **Native raster.** Confirm the printer's native pixel size for the 100 x 148 mm print and, if
   it differs from 1181 x 1748, regenerate: `python3 validation/make_chart.py --width <px>`
   (the manifest and the tests follow). Do not let the driver rescale; if it must, record it.
4. **Files from the app** (release 0.0.1 or later): load the chart and the photographs, output
   PNG, generate and save the corrected copies: once with Perceptual (V1) and once with
   Relative colorimetric, BPC off (V2, chart only). Keep the originals untouched.
5. **Run plan.** `python3 validation/make_run_plan.py --out Documentation/validation/run-plan.csv`
   gives a random print order with blind codes (P01 ...). Write only the code on the back of each sheet.

## Print session
- One paper/ink pack, same room, no sunlight on the sheets; record temperature, pack, driver and macOS versions.
- **Printer colour management** is switched OFF for V0, V1, V2 and the photographs, ON only for V3 and V4. Record *how* it is
  switched (app, dialog, option name) with a screenshot of the dialog: the print route is not
  part of the app yet. Try Preview first; if it does not offer the option, try Canon's app.
- Same scaling / borderless setting for every sheet, noted down.
- Print in the order of the run plan. Note anything odd (jam, colour cast, banding).

## Scanning
- Let the prints rest at least 24 hours (the overcoat and dyes settle).
- Scanner warmed up (30 minutes). One scan per print, no repeats. The whole print with its four corner marks
  must be in the scan; any orientation or a slight skew is fine.
- Same VueScan settings as when the scanner profile was made, all automatic corrections off
  (auto levels, colour restoration, sharpening, dust/grain), 16-bit TIFF, 600 dpi. Save the TIFF *without* applying your
  profile (device RGB), or with the profile embedded — never both, the analysis applies it. If the file is untagged
  pass `--scanner-icc`. Name the files by blind code.
- The chart sheets must be scanned with the print flat under the lid, glossy side down, always the same way.

## Analysis (after de-blinding with the run plan)
```
python3 validation/analyze_scan.py P05.tif --label V1 --out results --scanner-icc scanner.icc   # one per chart variant
python3 validation/report.py --results results --out results/REPORT.md
```
`REPORT.md` has the table of variants (with what the profile's own model predicts for comparison), the
groups, the gates below and the intent comparison. Copy `REPORT.md`, the CSV/JSON results, the run plan with
the key, the dialog screenshot and the filled `Documentation/validation/RUN_RECORD_TEMPLATE.md` into
`Documentation/validation/<date>/`. Do not commit scans or personal photographs.

## Gates (declared before printing)
| Gate | Meaning |
|---|---|
| G1 | V1 mean dE00 < V0 and V1 p95 <= V0 p95; a gain below 1 dE00 counts as "too small to interpret" |
| G1b | no more than a quarter of the patches that improve get worse (by more than 0.5 dE00) |
| G2 | neutral axis of V1: residual chroma C* p95 <= 3 from L* 25 up |
| G3 | V3 (CM ON) worse than V1 by more than 1 dE00: the printer does convert when asked to; if V3 = V1 the setting has no effect on this route |
| G4 | sheet uniformity: the four mid-greys within 1 dE00 (otherwise print/scan non-uniformity limits the conclusions) |

Photographs: compare V0 and V1 side by side under neutral light, record skin tones, shadows,
neutral cast, and the black-and-white verdict in the run record.

## Decisions this test drives
- Default intent (the model predicts Relative colorimetric closer on in-gamut colours; confirm with the photographs).
- Wording in the app for the printer's colour management (M4 must tell the user to switch it off).
- Recommendation for black-and-white photographs.
- Whether 1.0.0 may drop the "experimental" label (see `RELEASE.md`).

## Reference: what the model predicts (no print involved)
Mean dE00 on the chart from the profile's own A2B model: V0 about 8.9, V1 about 4.9, V2 about 3.0. A measured
result far from these figures means either the model or the print route (for example colour management) deserves a closer look.

## Limits
Dye-sublimation prints scanned with a CCD flatbed: metamerism and gloss make absolute dE00 approximate; the
ColorChecker check estimates, but cannot remove, that error. One print per variant: differences under about 1
dE00 are not interpreted.
