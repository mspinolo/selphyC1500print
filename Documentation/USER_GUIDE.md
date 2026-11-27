# SELPHY CP1500 Print — user guide

SELPHY CP1500 Print prepares photos for the Canon SELPHY CP1500 using the printer's ICC profile
from Farbenwerk: it converts each photo into the RGB numbers that, after the printer's own fixed
colour processing, should give the colours the photo is meant to have. The corrected copies are
ordinary sRGB-tagged files that you print as usual.

> **Status: experimental pre-release (0.0.x).** The correction follows the vendor's
> documentation and the profile's own model; it has not yet been confirmed with measured prints.
> The *Print validation assistant* (menu **Advanced**) is the way to check it on your printer.

## 1. Install and first launch

1. Download `SELPHY-CP1500-Print-<version>-macOS.zip` from the GitHub Releases page and unzip it.
2. The app is signed ad hoc and not notarised: the first time, right-click it and choose **Open**
   (or run `xattr -dr com.apple.quarantine "SELPHY CP1500 Print.app"` in Terminal).
3. Open **Settings** (⌘,) and choose the Farbenwerk profile (`.icc`) with **Choose profile…**, or
   drag the file onto the profile row. The app remembers it. The report under the name tells you
   whether it looks like a printer profile with the tables the correction needs.

Requirements: macOS 14 or later. The printer is added in System Settings > Printers & Scanners;
it prints through AirPrint (USB or Wi-Fi), without a Canon driver.

## 2. The main window

- **Photos** (left, can be hidden with ⌃⌘S): add JPEG, JPEG XL, PNG or TIFF files with **Add…** or by
  dragging them in. Click one to preview it. Originals are never modified.
- **Preview** (right): choose what to look at in the view menu:
  - *Original* — the photo with its own colours (wide-gamut files keep their gamut);
  - *Without correction* — the expected print if the photo is sent as it is;
  - *With correction* — the expected print of the corrected copy;
  - *Compare* — the two expected prints with a draggable divider;
  - *ΔE map* — where the corrected print still deviates (adjustable scale);
  - *Dark zones* — shadows darker than the printer's deepest black;
  - *Out of gamut* — colours the print makes duller;
  - *Postcard layout* — the corrected copy on the 100 × 148 mm sheet.
  Zoom with the zoom control; the line under the image reads the colour under the pointer.
- **Bottom bar**: the rendering intent (*Perceptual* by default; *Relative colorimetric* keeps
  in-gamut colours more exactly) and the output format (PNG lossless by default, or JPEG), then
  **Generate corrected copies**: every photo in the list is converted into a corrected copy (the
  originals are not touched). The copies appear in the strip above the bar, where you can
  **Print…** them or save them to a folder (they are temporary otherwise, removed after 24 hours).

The preview is a soft proof: it uses the printer profile's model and your display's profile.
*Simulate paper white* and *Monitor black* (view options) make it closer to the look of a print
on paper; they change only what you see, not the copies.

## 3. Full-screen view

Toolbar button with four arrows, **View > Full-screen view** or **⇧⌘F**. The photo is shown at full
resolution on darktable's middle grey (L* 50); the reduced preview appears at once and is replaced
when the full resolution is ready (the view on screen is computed first).

| Key | Action |
|---|---|
| 1 / 2 / 3 / 4 | Original / Without correction / With correction / Compare |
| S | compare side by side |
| Z | fit ↔ 100 % (one image pixel per screen pixel) |
| + / − , pinch | zoom; drag or scroll to move |
| ← / → | previous / next photo (or click a thumbnail at the bottom) |
| I | hide / show the indications |
| Esc | close |

## 4. Statistics

Toolbar button with the bar chart. A separate window that follows the photo in the preview:

- deviation statistics (mean, median, 95th and 99th percentile, maximum ΔE00) with a histogram
  coloured like the ΔE map, and the deviation by lightness zone;
- **ΔE00 distribution** — a waveform-like plot of the deviation along the image width or height,
  or against lightness L* (which tones print worst) or hue (which colours); hovering a strip in
  the width/height plots marks it on the preview;
- **colours and printer gamut** — the a*-b* outline of what the printer can reach against sRGB,
  with the photo's colours and the ones the print makes duller;
- the three rendering intents compared on the selected photo, with a suggestion and **Use**;
- a sortable table of all loaded photos (click a row to preview it) and CSV / PDF export.

All figures are predictions of the profile's model computed on a reduced copy, not measurements.

## 5. Printing

**Print…** opens the macOS print dialog for the corrected copy. Choose the SELPHY, paper size
**Postcard (100 × 148 mm)**, no extra colour options. On the printer, switch **Image Optimize** off
(Setup > Print settings): it is on by default and **returns to on when the printer switches off**, so
consider setting Auto power off to Off. Whether Image Optimize acts on AirPrint jobs at all is one
of the questions the validation assistant answers.

## 6. Print validation assistant (Advanced menu)

A guided version of [`PHYSICAL_VALIDATION.md`](PHYSICAL_VALIDATION.md), for anyone who wants to
check the correction on their own printer. It remembers where you are between sessions.

1. **Mode** — with a flatbed scanner (measured) or without (visual comparison).
2. **Reference chart** — the edition of your physical ColorChecker: Classic made before November
   2014 (default), from November 2014, the 2005 and 1976 data, the BabelColor average, ColorChecker
   SG before / from November 2014, or your own values (CSV or CGATS).
3. **Files to print** — the test chart (original, corrected Perceptual, corrected Relative
   colorimetric; with Image Optimize off and on) and up to four photographs of yours, exported
   with blind codes (P01, P02, …) in random order, plus the print order and a sealed key.
4. **Print session** — checklist and a record of the conditions.
5. **Scanner check** — scan the ColorChecker, click its four corner patches; the error of the
   scanner chain sets how small a difference between prints can be trusted, and the assistant
   warns when the scanner profile looks applied twice or not at all.
6. **Chart scans** — choose the TIFF of each chart print (or a folder with files named by code);
   the corner marks are found automatically, whatever the orientation.
7. **Photographs** — which print of each pair looks closer to the screen, chosen by code.
8. **Report** — table of the variants with what the model predicted, the pass/fail criteria
   declared beforehand (G1–G4), the intent choice, the photos' verdicts; export as `REPORT.md`
   with results in the format of the Python tools in `validation/`.

Scan settings that matter: all automatic corrections off, 16-bit TIFF, 600 dpi, the same settings
as when the scanner profile was made; save without applying the profile *or* with it embedded,
never both. Let prints rest 24 hours before scanning.

## 7. Settings

Profile, rendering intent and black point compensation (BPC is always on for Perceptual with a v4
profile, as the ICC specification requires), the folder for the temporary copies (the system one by
default; a chosen folder gets a subfolder "SELPHY CP1500 Print temporary", and only the app's own
sessions older than 24 hours are ever removed from it), language (English / Italiano), interface theme
(follow the system, light, dark, or **neutral grey** — darktable's grey, recommended when judging
colours) and the reminder shown before printing.

## 8. Limits

- The colour model is the profile's own prediction; prints can differ (paper batch, ink ribbon,
  printer unit, ageing). Only the validation tells how close it gets on your printer.
- The preview depends on your display's profile; an uncalibrated screen limits what it can show.
- Copies are 8-bit files (the printer receives 8 bits); conversions run at 16 bits.
- Very large photos take a few seconds at full resolution (full-screen view, export).

## 9. Troubleshooting

| Problem | What to do |
|---|---|
| "can't be opened because Apple cannot check it" | right-click → Open, or the `xattr` command above |
| no preview, message about the profile | choose the profile in Settings again (the file may have moved) |
| thumbnails stay grey | the file cannot be decoded by macOS; check it opens in Preview |
| prints look washed out or too contrasty | check Image Optimize on the printer (it turns itself back on) |
| scanner check far above 5 ΔE00 | profile applied twice / not at all, wrong chart edition, an automatic scan correction on |
