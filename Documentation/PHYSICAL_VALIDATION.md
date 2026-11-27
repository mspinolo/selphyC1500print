# Physical validation procedure (Canon SELPHY CP1500)

Goal: find out, with real prints, whether the pre-correction improves the printed colour, which
intent to make the default, and whether the printer's own **Image Optimize** (automatic brightness/contrast correction, On by default)
is really out of the way when it is switched off on the printer (the only setting that touches the colour).

Evidence level: **scanner-estimated colorimetry** (flatbed scanner + its ICC profile), not a
spectrophotometer. It resolves differences between variants well (same scan chain for all of
them); absolute dE values carry the scanner uncertainty measured in step 2. Photographs are also
judged by eye. This extends section 4 of `VALIDATION_PLAN.md`.

The app has a guided version of this procedure: **Advanced > Print validation assistant** (see
`USER_GUIDE.md`). It produces the same files, measurements and report as the Python tools below,
which remain the reference implementation.

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

| Variant | File printed | Printer *Image Optimize* | Purpose |
|---|---|---|---|
| V0 | original chart | OFF | baseline: what the printer does alone |
| V1 | chart corrected, Perceptual | OFF | main result |
| V2 | chart corrected, Relative colorimetric, BPC off | OFF | intent choice |
| V3 | same file as V1 | **ON** (printer default) | does the printer-side optimisation act on this route? |
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
2. **Scanner chain check.** Scan the ColorChecker with exactly the settings you will use
   for the prints. The reference Lab (D50) of the chart depends on its edition: the published
   values are in `validation/references/` (Classic before November 2014 — the default, the owner's
   chart —, from November 2014, 2005, 1976, BabelColor average; SG before / from November 2014).
   Read, in any image viewer, the pixel coordinates of the centres of dark skin (top-left),
   bluish green (top-right), white (bottom-left), black (bottom-right), chart upright, then:
   `python3 validation/check_scanner.py cc.tif --corners "x,y x,y x,y x,y" --out results`
   (add `--reference validation/references/<edition>.csv` for another edition, or your own file).
   Mean dE00 of a few units is normal for a flatbed; above about 5, suspect that the profile is applied twice
   or not at all (see scanning).
3. **Native raster.** Confirm the printer's native pixel size for the 100 x 148 mm print and, if
   it differs from 1181 x 1748, regenerate: `python3 validation/make_chart.py --width <px>`
   (the manifest and the tests follow). Do not let macOS/AirPrint rescale; if it must, record it.
4. **Files from the app** (release 0.0.1 or later): load the chart and the photographs, output
   PNG, generate and save the corrected copies: once with Perceptual (V1) and once with
   Relative colorimetric, BPC off (V2, chart only). Keep the originals untouched.
5. **Run plan.** `python3 validation/make_run_plan.py --out Documentation/validation/run-plan.csv`
   gives a random print order with blind codes (P01 ...). Write only the code on the back of each sheet.

## Print session
- One paper/ink pack, same room, no sunlight on the sheets; record temperature, pack, printer firmware and macOS versions.
- **Print route.** The CP1500 has no macOS driver: it is added in System Settings > Printers & Scanners
  (USB or Wi-Fi) and prints through AirPrint (Canon's macOS guide, see Sources). Use Preview (File > Print) with the
  Postcard paper size (100 x 148 mm) and record the dialog options.
- **Image Optimize** is a setting *on the printer*: Setup > Print settings > Image Optimize (Canon: it "automatically
  corrects brightness and contrast to suit each image", On by default). Canon states that these settings return to
  default when the printer is switched off, so: set Printer Setup > Auto power off to Off, switch Image Optimize to Off, and
  check it on the printer screen before **every** sheet. OFF for V0, V1, V2 and the photographs; ON (default) only for V3 and V4.
- **Open question this session answers.** Canon documents the Print settings for printing "from memory cards or USB
  flash drives"; the manual does not say whether they apply to AirPrint jobs from a computer. V3 against V1 (same
  file, only the setting differs) shows whether they do: if V3 = V1, the setting has no effect on this route. In that case
  the printer-side optimisation, if any, cannot be switched off from the printer for jobs from the Mac, and the
  question becomes whether AirPrint jobs are optimised at all; optional extra sheet to find out: print the *original* chart
  from an SD card or USB stick with Image Optimize OFF and compare with V0.
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
| G3 | V3 (Image Optimize ON) worse than V1 by more than 1 dE00: the printer-side optimisation acts on this route; if V3 = V1 the setting has no visible effect on it |
| G4 | sheet uniformity: the four mid-greys within 1 dE00 (otherwise print/scan non-uniformity limits the conclusions) |

Photographs: compare V0 and V1 side by side under neutral light, record skin tones, shadows,
neutral cast, and the black-and-white verdict in the run record.

## Decisions this test drives
- Default intent (the model predicts Relative colorimetric closer on in-gamut colours; confirm with the photographs).
- Wording in the app about the printer's Image Optimize (M4 must tell the user to switch it off, and that it resets at power-off).
- Recommendation for black-and-white photographs.
- Whether 1.0.0 may drop the "experimental" label (see `RELEASE.md`).

## Reference: what the model predicts (no print involved)
Mean dE00 on the chart from the profile's own A2B model: V0 about 8.9, V1 about 4.9, V2 about 3.0. A measured
result far from these figures means either the model or the print route (for example the printer's Image Optimize) deserves a closer look.

## Limits
Dye-sublimation prints scanned with a CCD flatbed: metamerism and gloss make absolute dE00 approximate; the
ColorChecker check estimates, but cannot remove, that error. One print per variant: differences under about 1
dE00 are not interpreted.

## Sources (Canon, checked 2026-11-24)
- Printing from macOS over USB (AirPrint, no driver; paper sizes L / Postcard / Card): https://cam.start.canon/en/P001/manual/html/UG-05_Print_USB_0030.html
- Print settings (Image Optimize, Color Adjustment, reset at power-off, scope "memory cards or USB flash drives"): https://cam.start.canon/en/P001/manual/html/UG-06_Set-up_0020.html

