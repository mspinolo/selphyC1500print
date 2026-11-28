# Changelog

Versioning: `0.0.x` pre-releases while verification is incomplete; `1.0.0` only once the
checklist in `Documentation/RELEASE.md` is fully ticked.

## [0.0.9] - 2026-11-28
Ninth pre-release. Not verified on physical prints.

### Fixed
- **The validation session could be lost without notice**: a session file that could not be read
  (damaged, or written by a later version) was replaced by a new session at the first change, and
  failed saves were silent. Now fields missing from an older file keep their defaults, a file that
  cannot be read is kept aside under a dated name and reported, and a failed save is reported
  until saving works again.
- The validation assistant renews the references (bookmarks) of files and folders that were moved
  or renamed, so that it keeps finding them.
- VoiceOver: completed steps were announced as "Selected"; gate results, the best intent, a photo
  that cannot be read and the full-screen close button now have labels; decorative icons are hidden.

### Changed
- Faster previews of photos with their own profile: the sRGB copy (the "without correction"
  simulation) is made from the pixels already decoded, on all cores, instead of decoding the file
  a second time (1400-pixel preview: 0.47 s -> 0.12 s for this step on the CI runner; at most one
  8-bit step of difference, in the comparison layer only).
- The full-screen view no longer decodes and keeps a second full-resolution copy of the original.
- Thread-safe caches use Swift's `Mutex`: their thread safety is now checked by the compiler.
- The profile is read in one place (`AppSettings.readProfile`); sandbox access to files goes
  through one helper.

### Tests
- Session storage (unreadable, older and future files, failed saves, moved files), the in-memory
  sRGB conversion (matches decoding again; strips do not change the result), VoiceOver labels,
  timings of the full-screen path by stage. 171 tests.

## [0.0.8] - 2026-11-28
Eighth pre-release. Not verified on physical prints.

### Fixed
- **Generating the corrected copies did nothing useful in the app**: the conversion started before
  access to the bookmarked printer profile was opened, so in the sandbox it could not read the
  profile and stopped with an error shown only in the status line. Access is now opened before the
  conversion (and by the conversion itself), and a failure is shown in an alert.

### Added
- Settings > **Temporary copies**: choose the folder for the generated copies (default: the system
  temporary folder). The app writes to a subfolder "SELPHY CP1500 Print temporary" there; if the
  folder cannot be reached, the system one is used and the status line says so.

### Changed
- The 24-hour clean-up removes only the app's own session folders (UUID-named) in its subfolder,
  nothing else.
- README brought up to date (printing, files and privacy, language setting, test suites).
- **Requires macOS 27.0 or later** (was 14). Built with Xcode 27.2 and Swift 6.4 in the Swift 6
  language mode (data races checked at compile time); deprecated APIs replaced. The minimum will
  move to macOS 27.2 once the CI runner can test on it.
- App state uses Swift **Observation** (`@Observable`) instead of `ObservableObject`: each window
  redraws only for what it shows. The interface language is observable too, so every open window
  changes language at once.

### Tests
- **Interface tests**: each window is opened in a real window and used through its accessibility
  tree (buttons, switches, radio groups, menus opened and items picked), checking what it shows
  and that the settings change; drawing-based checks that windows follow changes made elsewhere;
  observation tests for every model. 163 tests in all.
- "Generate test copies" is now **Generate corrected copies**, with a tooltip saying what it does
  and how many photos it converts; when it is disabled, the reason (no profile, no photos) is shown
  next to it.

## [0.0.7] - 2026-11-27
Seventh pre-release. Not verified on physical prints.

### Added
- **Print validation assistant** (menu Advanced): the physical test of
  `Documentation/PHYSICAL_VALIDATION.md` step by step, with or without a scanner. Test chart
  generated in the app (identical to `validation/charts/selphy_chart_v1.png`), files to print
  named by blind codes in random order with a separate key, print checklist and session record,
  scanner check on a clicked ColorChecker, automatic analysis of the chart scans (corner marks
  found in any orientation), blind visual verdicts on the photographs, report with the gates
  G1-G4 and the model's prediction, export compatible with the Python tools. The session is saved
  between launches.
- ColorChecker reference editions: Classic before November 2014 (default), from November 2014,
  2005, 1976, BabelColor average; SG before / from November 2014; import of your own values
  (CSV, CGATS / IT8 with LAB or XYZ). Also used by `validation/check_scanner.py`.
- Chart-scan analysis in the portable C core (`selphy_chart.c`), cross-checked against the Python
  reference on synthetic scans in CI.
- Statistics: a*-b* plot of the printer's gamut against sRGB with the photo's colours.
- Settings: drag an `.icc` file onto the profile row.
- `Documentation/USER_GUIDE.md`; README brought up to date.

### Changed
- Full-screen view: the view on screen is computed first at full resolution, then the others; the
  Original needs no correction and comes straight from the file.
- The preview's Original view shows the photo in its own colour space (wide-gamut files are no
  longer clipped to sRGB).
- Statistics histogram rebuilt (explicit bars and axes) to avoid the two Charts log warnings.

### Tests
- Input matrix: 16-bit precision, linear 16-bit input, Display P3 sources, 24-megapixel export
  timing.

## [0.0.6] - 2026-11-25
Sixth pre-release. Not verified on physical prints.

### Added
- Statistics: "ΔE00 distribution" scope for the selected photo, like a waveform. Each vertical
  line is the distribution of the predicted ΔE00 of the pixels in one strip, brighter where
  there are more pixels (log scale), coloured by ΔE00 band, with median and 95th-percentile
  lines and guides at 1, 3 and 6. The horizontal axis can be the image width, the image height,
  the lightness L* (which tones print worst) or the hue (which colours; pixels without a
  definite hue are left out). With width or height, the strip under the pointer is marked on
  the preview in the main window.

## [0.0.5] - 2026-11-25
Fifth pre-release. Not verified on physical prints.

### Added
- Interface theme in Settings: follow the system, light, dark, or neutral grey. The neutral grey
  theme takes its values from darktable 5.6's "elegant grey" theme: panels #6A6A6A, a middle grey
  #777777 (L* 50, no chroma) behind the photo, grey controls without the accent colour; it
  applies to all windows and to the system dialogs.

- Full-screen view (toolbar button, View menu, Shift-Command-F; off until called): the photo at
  full resolution on darktable's middle grey (#777777, L* 50), with the same soft-proof as the
  preview. Keys 1-4 for Original / Without / With correction / Compare, S side by side, Z fit or
  100% (one image pixel per screen pixel), +/- and pinch to zoom, drag or scroll to move, left and
  right arrows for the previous/next photo, I to hide the indications, Esc to close. At the bottom,
  thumbnails of the loaded photos to jump to one; the indications hide themselves after 2 seconds.
  The reduced preview appears at once and is replaced by the full resolution when ready; only the
  last two photos are kept at full size, and everything is freed on closing.
- The preview options (paper white, monitor black) are remembered and shared with the full-screen
  view.

### Fixed
- The Statistics window had no background of its own: its light-mode snapshot came out dark.

## [0.0.4] - 2026-11-25
Fourth pre-release. Not verified on physical prints.

### Changed
- Statistics is now a window of its own instead of a sheet: resizable, it can stay open next to
  the preview and follows the previewed photo; a click in its table selects the photo in the
  main window. Sortable columns, histogram coloured by dE00 band with mean and 95th percentile
  marked, best rendering intent highlighted with a "Use" button, progress counter, tooltips on
  the metrics.
- Settings: the rendering intent is also shown next to black point compensation (same setting
  as the main window); "Show in Finder" for the profile.
- About window: credits and the full LittleCMS licence text (also included in the app bundle).

### Performance
- Moving the pointer over the preview redraws only the readout line (in the Dark zones and Out
  of gamut views the highlighted share was recomputed over every pixel at each move).
- The analysis computes the Lab values once (new core function `selphy_analyze_photo_lab`):
  about a third less work per photo and per intent change; results are identical.
- Statistics: each photo is decoded once for the three intents, several photos are analysed at
  the same time, and results are kept while the app is open (reopening the window is instant).
- Thumbnails are cached.

### Fixed
- Preview caches identified ICC profiles by length and first 80 bytes only: two different
  profiles with the same header could share cached results. They now use a SHA-256 digest.

## [0.0.3] - 2026-11-25
Third pre-release. Not verified on physical prints.

### Added
- Statistics window: deviation distribution of the selected photo (histogram, median and
  percentiles, shares above thresholds, split by lightness zone), table of all loaded photos,
  comparison of the three rendering intents with a suggestion, CSV and PDF export.
- Preview views: Dark zones (shadows the printer cannot reproduce, adjustable margin), Out of
  gamut (adjustable chroma loss), Postcard layout (Fit/Fill with the cut part dimmed); adjustable
  dE scale with a colour legend; zoom 100/200/400%; readout of the colour under the pointer
  (original and predicted Lab, dE00).

### Fixed
- The Settings button in the toolbar did nothing (macOS 14+).
- Thumbnails stayed on the placeholder for some photos: access to listed photos is now held,
  with fallbacks and a warning icon on failure.

### Changed
- CI: actions/checkout and actions/setup-python updated to v7 (Node 24).
- CI: actions/upload-artifact v7, actions/download-artifact v8 and softprops/action-gh-release v3 (Node 24; removes the Node 20 deprecation warning). Note: the release job with these versions is first exercised by the next release.

## [0.0.2] - 2026-11-24
Second pre-release. Not verified on physical prints.

### Added
- Print… button: sends the generated copies to the macOS print dialog (AirPrint), fit/fill
  placement, one sheet per image, notice about printer-side Image Optimize.
- New window layout: photo list with thumbnails (hideable, drag and drop) next to a large
  preview; choose which photo the preview shows; bottom bar with the main options; Settings
  window (Cmd-,). Default size 980 x 680.
- App icon.
- Dark mode: the main pane now has its own appearance-aware background (it rendered white under
  light text in the dark-mode snapshot).
- App quits when its window is closed (it no longer stays running in the background).

## [0.0.1] - 2026-11-24
First pre-release. Not verified on physical prints and not yet checked by the owner on a Mac.

### Added
- Colour pre-correction of photos for the Canon SELPHY CP1500 through the Farbenwerk ICC
  profile (vendored LittleCMS 2.20); the corrected values are tagged sRGB.
- Inputs: JPEG, JPEG XL, PNG, TIFF (embedded profiles honoured; greyscale, CMYK and Lab
  converted to sRGB first). Output: PNG (lossless, default) or JPEG.
- Print preview: original, predicted print without and with correction, split comparison,
  ΔE map, paper-white simulation, per-photo checks (not reproducible colours, shadows,
  black-and-white tint). In-memory cache for fast option changes.
- Saving corrected copies to a remembered folder (never overwrites or deletes), progress and
  cancellation, profile report restored at launch.
- Sandboxed `.app`, ad-hoc signed, not notarised.
- Interface in English (default) or Italian, selectable in the app.

### Known limitations
- Preview and corrections are model-based; no physical print has validated them yet.
- Printing from the app is not available yet; copies are saved and printed by other means.
- No app icon.
