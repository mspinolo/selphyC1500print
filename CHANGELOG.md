# Changelog

Versioning: `0.0.x` pre-releases while verification is incomplete; `1.0.0` only once the
checklist in `Documentation/RELEASE.md` is fully ticked.

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
