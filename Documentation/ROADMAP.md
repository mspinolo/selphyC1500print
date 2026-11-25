# Project roadmap (v2)

Working plan for `selphyC1500print`. The repository is the source of truth; update this file whenever a task is completed, deferred or blocked. Every item is labelled by evidence level: **implemented** (code exists), **tested** (automated test passes in CI), **validated** (confirmed on physical prints).

## Goal

A native macOS utility that pre-corrects photos for the Canon SELPHY CP1500 using the Farbenwerk CP1500 ICC profile, with a transparent, reproducible colour pipeline and safe handling of originals. The colour model is **trusted per vendor** (Farbenwerk profile plus the vendor's printer-setting instructions), not yet validated on physical prints; the app stays labelled experimental until the optional physical track (P) is done.

## Where the project actually stands (2026-11-24)

- Implemented: SwiftUI shell, ICC header/tag inspector, pre-correction in the portable LittleCMS-based colour core (source RGB -> PCS -> printer B2A, 16-bit internally, result tagged sRGB), batch export to a temporary folder, read-only treatment of originals.
- Tested: portable core tests (CMake/ctest, Linux CI) and macOS integration tests. The earlier ColorSync-vs-LittleCMS raw-code comparison is retired (see Findings).
- Validated: nothing yet. The owner cannot run physical prints for now and relies on the vendor's profile and printer-setting instructions. The premise "pre-corrected sRGB-tagged output prints better" is therefore *accepted on trust*, and every release note must say so.
- The Farbenwerk profile is ICC v4.3, committed at the repository root by explicit owner decision (not reopened). README, VALIDATION_PLAN and `.gitignore` now say so, and CI uses the committed copy.

## Findings (CI run 76, commit 8a9742c)

Measured with the real profile on a 32-patch sRGB chart; errors are raw 8-bit code differences between ColorSync and LittleCMS.

- **Relative colorimetric, BPC off:** engines agree (mean 0.59, p95 1, max 3).
- **ColorSync ignores BPC on the destination (printer) entry:** with BPC only on the destination, ColorSync's output is byte-identical to no BPC. Only the source entry has any effect, and its result matches neither LittleCMS BPC off (mean 10.7) nor on (mean 8.8). The production code sets both entries, so it behaves as "source entry only".
- **LittleCMS semantics are well defined:** in a two-profile chain only the second BPC entry matters; the printer's relative-colorimetric black point is L* = 13.2, so BPC on remaps a large part of the shadow range (81 of 96 bytes change).
- **Perceptual:** all four LittleCMS BPC combinations give identical output, consistent with LittleCMS forcing BPC for ICC v4 perceptual transforms (printer black L* = 3.14, the v4 perceptual reference black). ColorSync with BPC off lands within mean 1.52 / max 11 of it.

Interpretation (engineering inference, not print-validated): the BPC toggle in the UI has no specifiable meaning under ColorSync, while LittleCMS gives documented behaviour. This pushes Decision 3 toward LittleCMS; the DeltaE harness in M1 confirms or refutes it.

## Decisions taken in this revision

1. **Physical validation is a non-blocking track (P).** The owner cannot print comparisons yet and trusts the vendor's profile and settings, so software work proceeds on that assumption. Track P stays in the plan and is picked up whenever prints become possible; nothing is allowed to claim colour accuracy before then.
2. **Measure in colour, not in raw codes.** Raw 8-bit RGB differences are meaningless where the B2A tables are steep. The metric is DeltaE2000 in Lab. Besides comparing engines, use the profile's own forward model as the closed-loop check: `intended Lab = source -> Lab`, `predicted print Lab = printer A2B(output RGB)`; the DeltaE00 between them (in-gamut patches) says how good a pre-correction is without any second CMM.
3. **Engine decision gate (M1).** ColorSync is not assumed to stay the production engine. If ColorSync cannot reproduce documented, predictable BPC and v4 perceptual behaviour (hypothesis to check: LittleCMS forces BPC for v4 profiles with perceptual/saturation intents, ColorSync with BPC off may not), switch production to LittleCMS (MIT licence, deterministic, 16-bit/float pipeline, runs on any CI) and keep ColorSync as a cross-check only.
4. **Research probes are not product tests.** BPC placement probes and black-point inspection move out of the main suite (separate target or opt-in env var) and report numbers instead of asserting arbitrary limits. Product tests assert behaviour with justified tolerances.
5. **Tolerances follow the metric.** "Never widen thresholds" is dropped; thresholds are defined once, in DeltaE00, with a stated reason, before looking at results.

## Milestones

### M0 - Honest baseline (small, first)
- [x] Fix README, VALIDATION_PLAN, `.gitignore`: describe the committed profile truthfully; CI uses the repo copy (download step removed).
- [x] No Homebrew dependency any more (LittleCMS vendored). [ ] Record the macOS / Xcode / Swift versions used by CI in this file.
- [x] Known ColorSync/LittleCMS divergences recorded as strict expected failures (thresholds unchanged, still reported, test fails if they start passing); CI publishes test numbers as annotations. Replaced by the DeltaE metric in M1.
- [ ] Remove or clearly label unused assets (the 6 MB third-party TIFF is referenced by no test; confirm its licence).

**Exit:** green CI on a clean checkout; docs match reality.

### M1 - Colour engine decision (done)
- [x] DeltaE2000 harness: printer A2B forward model vs intended Lab (`selphy_printer_predict_lab`, `selphy_source_to_lab`, `selphy_delta_e2000`).
- [x] BPC discrepancy resolved from the LittleCMS source (`cmscnvrt.c`): BPC entry `i` acts between profile `i-1` and `i`, so only the printer entry matters in a two-profile chain; BPC is forced for ICC v4 profiles with perceptual/saturation, never applied for absolute colorimetric. The UI toggle is therefore disabled where it has no effect.
- [x] Decision: **LittleCMS is the production engine** (vendored lcms2.20, MIT). ColorSync is removed: its BPC cannot be specified (destination entry ignored, source entry matches neither LittleCMS setting).
- [x] Portable core `SELPHYColorCore` (C) with its own Linux/CMake test suite; Swift is a thin shell. Mutation-checked: injected defects (BPC always on, wrong intent table, wrong rounding) are detected.
- [x] Real defect found and fixed by the new tests: a truncated printer profile was silently accepted (LittleCMS reads lazily); the ICC declared size is now validated.
- [x] macOS CI green for the Swift shell (run 81: 19 tests, 0 failures; Linux core job green). End-to-end through the real pipeline and the profile's own model: mean deviation 9.25 -> 3.08 DeltaE2000; neutral steps and skin tones 0.0-0.5.

**Evidence (core tests, real profile, 32-patch sRGB chart, relative colorimetric, BPC off):** optimised vs exact pipeline mean 0.03 / max 0.20 DeltaE2000; through the profile's own model the correction reduces the mean deviation from 9.25 to 3.00 DeltaE2000, neutral steps (L* >= 27) and skin tones land within 0.35, no patch is worse than uncorrected. The remaining error is outside the printer gamut (saturated primaries, about 10 DeltaE2000) or near black (the printer's black is L* 17.9, relative; 2.8 on the v4 perceptual scale). This is a statement about the model, not about prints.

**Exit:** one production engine, documented BPC semantics, DeltaE00 tolerances recorded in the tests.

### M2 - Pipeline hardening
- [x] 16-bit internal processing in the core (single final rounding); lossless PNG output as a precaution.
- [x] Real JPEG penalty measured (CI, macOS 27, 96x64 textured image with +-8 noise, dE00 through the printer's A2B, corrected PNG vs the same re-encoded as JPEG): quality 0.98 mean 0.66 / max 4.1; 0.90 mean 0.73 / max 4.4; 0.80 mean 0.84 / max 4.5. The mean is comparable to the colour residual of the correction itself, so PNG stays the default and JPEG stays an explicit, labelled option (quality 0.98). The earlier suspicion that JPEG caused 5-11 dE errors was wrong: it was a test bug (CoreGraphics bottom-left origin).
- [x] 16-bit decode of the source for every input, including EXIF-rotated images (orientation applied while writing the converted pixels, no thumbnail API); alpha composited on white; input JPEG/JPEG XL/PNG/TIFF; output PNG (default) or JPEG (quality 0.98).
- [x] EXIF orientations 1-8 verified pixel by pixel against the geometric definition (lossless TIFF fixtures).
- [x] Output resolution: the source DPI is carried over (axes swapped for orientations 5-8); nothing is invented when the source has none.
- [x] Source handling: embedded Adobe RGB honoured; grayscale, CMYK, Lab and indexed sources are converted to sRGB by Core Graphics and then corrected (reported in the UI); other colour models are rejected with a clear error. A JPEG without an ICC segment is treated as sRGB; note that ImageIO reports sRGB for such files, so they cannot be told from tagged sRGB and no "assumed" warning can be given for them.
- [x] Memory bounds: 100 MP cap checked before any allocation (unit-tested); the 16-bit working buffer is released after conversion.
- [x] Per-pixel packing loops replaced: rows are converted in blocks, in parallel (the transform is lock-free: no cache, no shared scratch), with unaligned 16-bit loads.
- [x] CI records the macOS / Xcode / Swift versions.
- [ ] Remaining validation-matrix gaps (see `VALIDATION_PLAN.md`): 16-bit and linear inputs (the unused ProPhoto 32-bit TIFF fixture needs a licence check before use), very large images (timing), Display P3 source.

**Exit:** the validation matrix in `VALIDATION_PLAN.md` is fully automated and green.

### M3 - Real application
Order of work: M3.1 preview first (it is also the tool to judge the correction without printing), then the bundle, then the rest.

**M3.1 Soft-proof preview (model-based) - implemented, to be checked on the owner's Mac**
- [x] Core: `selphy_preview_create/apply_rgb8/free` (printer profile as input device profile -> display profile; relative colorimetric, optional paper-white simulation = absolute, optional black stretch; out-of-display-gamut pixel count). Portable C, tested on Linux (mutation-checked: BPC entry, paper white, gamut count). A printer profile is rejected as display profile.
- [x] Core tests, results: preview vs the independent A2B Lab model <= 0.54 dE00 (neutrals, skin); with correction the preview is 3.0 dE00 from the original, without 9.0 (same figures as the model check); paper white 255/255/255 relative vs 240/240/245 absolute; the printer's black shows as a lifted dark with a bluish cast (17/36/51), 0/6/36 with the black stretch; 213 of 729 device colours fall outside sRGB, the neutral axis never does.
- [x] Swift: `PreviewService` (reduced-size decode through the export code path, EXIF orientation, corrected vs uncorrected device values, display profile with sRGB fallback), `PreviewPanel` (Original / Without / With correction / Compare with a draggable divider, re-rendered when photo, intent, BPC or options change). macOS CI: preview with correction 3.05 dE00 from the original, without 9.00; size reduction, orientation, display fallback and no-clipping-for-neutrals tested.
- [x] Display profile: taken from the screen's ColorSync profile, sRGB fallback if unusable.
- [x] UI wording: simulation from the printer profile, not a print proof, not validated with physical prints; out-of-gamut share shown when above 0.5%.
- [ ] Owner check on a real Mac (not verifiable in CI): the panel layout and the slider, the display profile of a wide-gamut screen (P3), responsiveness on a large photo.
- [ ] Known limits: the preview normalises the original to sRGB (a wide-gamut source is shown clipped to sRGB in the "Original" view); gamut-clipping count is best effort for display profiles that clip in float.

**M3.1b Colour details and per-photo checks - implemented, to be checked on the owner's Mac**
Measured on the real profile, corrected neutral ramp (model, predicted print vs intended appearance):

| Rendering | Shadows | Neutrals |
|---|---|---|
| relative, BPC off | source levels 0-45 (of 255) all print as the darkest tone, L* 17.8, slight blue cast (C* ~4); separation is lost | from level 50 (L* ~21) upwards C* <= 0.9, dE00 < 1 |
| relative + BPC | levels 0-20 still collapse; separation from level ~30; dE00 3.6-6 in the shadows | C* <= 0.3 from level 40 |
| perceptual | no collapse, smooth compression; tones lifted by 3-7 L* | C* up to 3.7 in the shadows, ~1-1.6 in the mid tones |

Correction of an earlier statement: the darkest the printer can print is L* 13.2 (device RGB 0,0,0), but with a strong blue-cyan tint (about 17/36/51 on screen); the correction does not use it and aims at about L* 17.8, nearly neutral (device 31/19/0). That is the "darkest tone" used by the checks. LittleCMS's black point estimate (13.2) matches the device black, it is not an error.
- [x] Core `selphy_analyze_photo` (dE00 mean/p95/max, share not reproducible > 3, darkest tone, share below it, neutral share and residual chroma, per-pixel dE map); Linux tests (independent recomputation of the dE map, shadow share and darkest tone; uncorrected vs corrected neutral tint); mutation-checked (dE threshold, shadow threshold, chroma taken from the wrong image).
- [x] Swift: stats, translucent dE heat map ("Mappa dE" view), collapsible "Dettagli colore" panel (meaning of the three views, source profile and interpretation, display profile, checks, black-and-white note). CI: grey/red/dark-grey stats, heat map, descriptions.
- [x] Measured relative + BPC vs perceptual vs relative on shadows (table above).
- [ ] Decide what the UI recommends for black-and-white photos (needs a print to judge shadow detail against neutrality; for now the panel only reports residual tint and the share of shadows below the darkest tone).
- [x] Preview speed: `PreviewSession` keeps the stages in memory (decoded and corrected buffers, checks and dE map per photo/intent/BPC/profile, the printer-to-display transform, the two renderings; LRU 3/6/8 entries; invalidated by the file's modification date read from the file system - a test caught that `URL` caches it). The checks and the dE map run on a copy reduced to 512 px, the out-of-gamut share on the same sample. CI runner, 3000x2000 source: 6.0 s before, now 1.9 s cold, 0.8 s when only a display option changes, 5 ms for an identical request. Counters in the tests assert that nothing is recomputed that should not be.
- [ ] Later, lower priority: a*-b* plot of the printer gamut versus sRGB with the photo's colours.

**M3.2 Application shell**
- [x] `.app` bundle: `scripts/make-app.sh`, `Packaging/` (Info.plist, sandbox entitlements incl. bookmarks.app-scope), ad-hoc signed in CI, signature/plist/entitlements verified, zip uploaded as artifact. No notarisation (owner decision, no Developer ID; see `Documentation/RELEASE.md`); app icon still missing. Sandbox behaviour must be checked on a real Mac.
- [x] Save the corrected copies to a user-chosen folder ("Salva in una cartella..."): `ExportService` only adds files (existing names get " 2", " 3"), never overwrites or deletes, removes only what the failed call itself created; temporary copies stay until the 24-hour cleanup; outputs are named `<name>_SELPHY.<ext>`; the settings used are shown. Tested (clash, repeat, partial failure, not a folder).
- [x] Remembered save folder (bookmark, "Salva in <cartella>" / "Salva in un'altra cartella..." / "Dimentica"; an unreachable folder asks again); progress (n/total) and "Annulla" (checked between photos, leaves no temporary folder, sources untouched); profile report shown again at launch. Tested: bookmark round trip, progress sequence, cancellation.
- [x] Input scope: JPEG, JPEG XL, PNG, TIFF (HEIC not included).
- [x] UI language: English by default, Italian selectable in the app (`Localization.swift`, `ItalianStrings.swift`; a test checks that every text used in the code has an Italian entry with matching placeholders).

### M4 - Print submission (no longer gated on physical prints)
- [ ] Verified facts (Canon manual, 2026-11-24): the CP1500 has no macOS driver and prints from a Mac through **AirPrint** (USB or Wi-Fi), paper sizes L / Postcard (100 x 148 mm) / Card. The only setting that touches colour is **Image Optimize** (Setup > Print settings on the printer; automatic brightness/contrast correction; On by default; resets to default at power-off). Canon documents the Print settings for memory cards / USB flash drives and does not say they apply to AirPrint jobs: open question, answered by variant V3 vs V1 of the physical test. The app must tell the user to switch Image Optimize off, that it resets at power-off (Auto power off can be disabled in Printer Setup), and cannot set it itself.
- [ ] Record the vendor's printer-setting instructions verbatim-in-substance in `Documentation/PRINT_SETTINGS.md` (owner to supply), and design the print route around them (sRGB pass-through, no second conversion, no printer-side enhancement).
- [x] (4a, done, CI green; untested on a real Mac/printer) Route: the macOS system print dialog (AirPrint is the only path; a Canon driver does not exist), sizing/fit/borders for 100 x 148 mm (Postcard); job status, errors, cancellation; temp-file lifetime. Direct IPP is a later option only if the dialog proves insufficient.
- [x] (4a) Ship behind an "experimental, vendor-trusted colour model" notice: shown before printing (Image Optimize off, Postcard, no scaling), can be silenced; `com.apple.security.print` entitlement added. Open: `Documentation/PRINT_SETTINGS.md` (owner to supply vendor instructions); 4b below.
- [ ] Route-equivalence check on the first print day (Track P): the same corrected chart printed through the app and through Preview/Canon's app must give indistinguishable sheets, otherwise the route alters colour.

### M3.3 - Guided validation assistant (decided: for all users; deferred, to be built after M4 and the first real session)
- [ ] Wizard in the app built on `Documentation/PHYSICAL_VALIDATION.md`: what to print and how, ordered file export with blind codes, guided loading of the scans, analysis and report with the gates. Built *after* the first real session so that the procedure is frozen by experience; the Python tools in `validation/` are the reference implementation the app's analysis is cross-checked against (same synthetic scans, same numbers). The analysis goes into the portable C core so it is tested on Linux too.
- [ ] **Audience: all users** (owner decision, 2026-11-24), under an "Advanced" area, with a reduced scanner-less mode (visual side-by-side comparison of original/corrected prints).
- [ ] **Selectable reference chart and version** (owner decision): the user picks which colour target they own (ColorChecker Classic 24, and further models such as Passport/Mini/SG or an IT8 as they are added) and which edition/production year; reference values live in data files, one per target/edition, plus import of the user's own values (CSV / CGATS). Bundle reference values only if their licence allows it; otherwise the user supplies them. The wizard must state which reference was used in every report.
- [ ] Scanner side: accept the user's own scanner profile (embedded or separate) and explain the "profile applied twice or not at all" trap; the chain-error check on the target gates how far the results are trusted.
- [ ] Depends on: the ColorChecker reference version (owner), the M4 print route.

### M5 - Window redesign and app icon (after M4)
Owner feedback (2026-11-24, screenshot of release 0.0.1): the window is unattractive, unprofessional and badly sized.
- [x] Observed defects fixed in the first pass (pending the owner's look at a real window): default size 980 x 680 (minimum 760 x 520, was 900 tall); large preview that grows with the window; controls moved to one bottom bar (intent, format, generate) with explanations as tooltips; profile, BPC, language and print notice moved to a Settings window (Cmd-,).
- [x] Layout chosen by the owner (proposal A, 2026-11-24): two panes. The left column lists the photos with thumbnails, can be hidden (toolbar button or Ctrl-Cmd-S, remembered) and chooses which photo the preview shows; drag and drop of photos onto it; keyboard/VoiceOver labels on the rows; light and dark mode.
- [ ] Still to do for M5: owner review of the CI snapshots (artifact `window-snapshots`, English/Italian, light/dark, sidebar hidden, Settings) and fixes; remembered window size check on a Mac; drag and drop of the profile; Italian fit check on the real window.
- [x] Review loop: a test renders the window in several states (`WindowTests.testRenderWindowSnapshots`, enabled by `SELPHY_SNAPSHOT_DIR`) and CI uploads the images as the `window-snapshots` artifact (the step never fails the build).
- [x] App icon (owner chose "printout coming out of a printer", 2026-11-24): original artwork drawn by `scripts/make-icon.py`, delivered as `Packaging/AppIcon.icns` (all standard sizes), named in Info.plist, copied by `make-app.sh`, checked by `verify-app.sh` and by a test.
- [x] Defect (reported 2026-11-24): closing the window left the process running with no way to reopen a window (the "New Window" command is removed). Fixed: the app quits when its last window closes (`AppDelegate`, tested).

### M5b - Analysis tools (owner requests, 2026-11-24, after trying release 0.0.2)
- [x] Bug (fixed in 0.0.3): the gear button in the toolbar did nothing (the "showSettingsWindow:" responder action no longer works on macOS 14+): now uses `@Environment(\.openSettings)`.
- [x] (done in 0.0.3, to be checked on a Mac) Colour-deviation statistics for the loaded photos (beyond the current mean / 95th percentile / shares): dE00 histogram, median/max, shares above user-chosen thresholds, split by lightness zones (shadows, mid-tones, highlights); a summary table across all loaded photos to spot the problematic ones.
- [x] dE map with a user-adjustable scale (low and high dE for the colour ramp, with a legend) instead of the fixed 1 / 3 / 6.
- [x] "Too dark" overlay: highlight the pixels darker than the darkest tone the printer reproduces (merged or compressed shadows), with adjustable margin.
- [x] Out-of-gamut overlay: highlight the colours the printer cannot reach (saturated colours that are clipped or compressed), with adjustable sensitivity.
- [x] Pixel inspector: original colour, predicted print colour (Lab) and dE00 under the cursor.
- [x] 1:1 zoom and pan in the preview.
- [x] Postcard crop guide (100 x 148 mm): show on the preview what "Fill the paper" would cut, and the white margins of "Fit".
- [x] Automatic comparison of the three rendering intents per photo (mean/p95 dE, shadows, out-of-gamut share) with a suggestion of the best one and the reason.
- [x] Export of the analysis (statistics table, per photo) as CSV and PDF.
- [x] Bug (owner, 2026-11-25): some thumbnails stayed on the placeholder icon. Cause not reproducible here (no Mac): hardened on three fronts: the sandbox access of every picked or dropped photo is now held while it is in the list (`PhotoAccess`), the thumbnail falls back to the embedded thumbnail and then to a full decode and scale, and a failure shows a warning icon instead of the placeholder. To be confirmed by the owner on the same photos.

- Implementation notes (0.0.3): the Statistics window (toolbar) shows the deviation distribution of the selected photo (histogram, median, 95th/99th percentile, shares above 1/2/3/6, split by lightness zone), the table of all loaded photos (worst first) and the three intents compared with a suggested one (lowest mean dE00, with caveats about shadows); CSV and PDF export. The preview has the views Dark zones (adjustable margin), Out of gamut (adjustable chroma loss), Postcard layout (Fit/Fill, cropped part dimmed), an adjustable dE scale with legend, zoom (Fit/100/200/400%) and a pixel readout. Everything is computed on a reduced copy (512 px) from the printer profile's model.
- [ ] Open: the "out of gamut" overlay is a model heuristic (chroma the print loses against the intended colour), not a gamut-boundary test; check it against real prints on print day.

### M5c - Performance and secondary windows (owner request, 2026-11-25; done in 0.0.4, to be checked on a Mac)
- [x] Pointer readout no longer redraws the whole preview panel (the Dark zones / Out of gamut share was recomputed over every pixel at each pointer move); the share is computed with the overlay.
- [x] One Lab pass: `selphy_analyze_photo_lab` returns the intended and predicted Lab with the statistics and the dE00 map (the app recomputed them with two extra unoptimised transforms, about 37% more analysis time; values are identical, checked by a core test).
- [x] Statistics: a photo is decoded once for the three intents, photos are analysed 2-4 at a time, results are kept for the session (`AnalysisStore`, keyed by file, date, intent, BPC and profile digest).
- [x] Thumbnail cache (`ThumbnailCache`, by path, date and size).
- [x] Cache keys use a SHA-256 digest of the ICC profiles (`Data.hashValue` only looks at the first 80 bytes).
- [x] Statistics is a window of its own (resizable, can stay open next to the preview, follows the previewed photo; a click in the table selects the photo in the main window too); sortable columns; histogram coloured by dE band with mean and 95th percentile marked; best intent highlighted with a "Use" button; progress counter; tooltips.
- [x] Settings: rendering intent next to BPC (same setting as the main window), "Show in Finder" for the profile.
- [x] About window: credits and the full LittleCMS MIT licence (also as `Licenses/LittleCMS-LICENSE.txt` in the bundle).
- [ ] Open: confirm on a Mac that the Statistics window remembers its size and position, and the speed of the statistics with many photos.
- [x] (0.0.5, owner request) Neutral grey interface theme for judging colours, after darktable 5.6's grey theme (values from darktable-elegant-grey.css / darktable.css: bg #6A6A6A, darkroom background #777777 = L* 50); Settings > General > Interface theme. Fix: the Statistics window now paints its own background (light snapshot was dark).
- [ ] Open: owner check of the grey theme on a Mac (contrast of secondary text, toolbar, sidebar, dialogs).
- [x] (0.0.5, owner request) Full-screen view at full resolution on darktable's middle grey, on request only (Shift-Command-F / toolbar / View menu): views 1-4, side by side, fit/100%/zoom/pan, previous/next, thumbnail strip, self-hiding indications; reduced preview first, full resolution in the background (last two photos kept).
- [ ] Open: owner check on a Mac: speed of the full resolution on large files, memory, behaviour on a second screen and with the main window in macOS full screen.

### M6 - Release
- [ ] User documentation with limitations, release checklist, versioned releases. Keep the "experimental" label until track P has produced evidence.

## Track P - Physical validation (optional, owner-scheduled)
- [ ] **To check at the first physical print:** whether the printer's **Image Optimize** (printer menu, On by default, resets at power-off) really is off and whether it affects AirPrint jobs from the Mac at all (V3 vs V1). Owner's earlier note: it is the only setting that can be changed. If it has no effect on this route, find out (optional SD-card/USB-stick sheet) whether AirPrint jobs are optimised; the corrected file must not be converted or enhanced a second time.
- [ ] **Owner to do:** find the version/production year of the ColorChecker Classic (it decides the reference Lab values) and pass it on; then the matching reference file goes into `validation/` and `check_scanner.py` can be run. Also needed before print day: how VueScan outputs the scan (profile applied or not), and the printer's native raster.

Not blocking. Procedure and tools: `Documentation/PHYSICAL_VALIDATION.md` (`validation/`: chart generator, scan analysis, scanner check, report, self-tested with synthetic scans). First session planned for the owner's physical prints (13 sheets, ColorChecker-checked scanner chain, no repeats). Original sketch: matched uncorrected/corrected chart set (ramps, shadow steps, skin tones, primaries, gradient, one photograph) at the printer's native raster, 3 repeats, same paper pack and settings, randomised order, neutral light, measured patches if an instrument is available; results in `Documentation/validation/`. Use it to confirm or revise the default intent/BPC and the print-path identity assumption.

## Working rules
1. Never modify user source images.
2. Do not claim colour accuracy from a build or a passing test; label evidence level.
3. Keep personal photographs and print outputs out of the repository unless cleared. The Farbenwerk profile at the root is an explicit owner-approved exception.
4. Do not iterate on hypotheses through CI one push at a time: reason first, batch diagnostics, then push.
5. Small, reviewable commits; README must match actual behaviour.
