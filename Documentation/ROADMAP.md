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

**M3.1b Colour details and per-photo checks (before the `.app` bundle)**
Measured on the real profile, corrected neutral ramp (model, relative colorimetric, BPC off): neutral from source level 50/255 (L* ~21) upwards, residual chroma C* <= 0.9 and dE00 < 1; levels 0-30 all print as the printer black (L* 17.8) with a slight blue cast (a* 1.1, b* -4.0, C* ~4): shadow detail collapses. Perceptual keeps shadow separation but lifts tones by 3-7 L* and leaves C* up to 3.7. Relative + BPC not yet measured.
- [ ] Core: per-image statistics from a preview-sized buffer: share of pixels not reproducible (dE00 > 3 between intended and predicted), share of pixels in collapsing shadows, mean and 95th percentile dE00, maximum residual chroma for near-neutral images (black-and-white detection). Linux tests with known inputs (neutral ramp, saturated primaries, mid grey) and mutation checks.
- [ ] Core: per-pixel dE00 map (original vs predicted print) for a heat-map overlay.
- [ ] Measure and record the shadow behaviour of relative + BPC versus perceptual (ramp, same method), and decide what the UI should recommend for black-and-white photos.
- [ ] Swift/UI: collapsible "Colour details" panel (closed by default): colour space and meaning of the numbers of each of the three views, display profile in use, the per-photo checks above, black-and-white note; heat-map toggle.
- [ ] Later, lower priority: a*-b* plot of the printer gamut versus sRGB with the photo's colours.
- [ ] Wording: all of it is a model estimate, to be confirmed with a print.

**M3.2 Application shell**
- [ ] Proper `.app` bundle (Xcode project or build script), Info.plist, sandbox entitlements consistent with the security-scoped bookmarks, optional signing/notarisation, CI artifact.
- [ ] Export to a user-chosen folder instead of a hidden temp folder; progress and cancellation; clear errors; show the profile report again after a restart.
- [x] Input scope: JPEG, JPEG XL, PNG, TIFF (HEIC not included).
- [ ] UI language (Italian now; decide whether to localise).

### M4 - Print submission (no longer gated on physical prints)
- [ ] Record the vendor's printer-setting instructions verbatim-in-substance in `Documentation/PRINT_SETTINGS.md` (owner to supply), and design the print route around them (sRGB pass-through, no second conversion, no printer-side enhancement).
- [ ] Choose the route (system print dialog, AirPrint/IPP, or hand-off to the Canon app); sizing/fit/borders for 100 x 148 mm; job status, errors, cancellation; temp-file lifetime.
- [ ] Ship behind an "experimental, vendor-trusted colour model" notice.

### M5 - Release
- [ ] User documentation with limitations, release checklist, versioned releases. Keep the "experimental" label until track P has produced evidence.

## Track P - Physical validation (optional, owner-scheduled)
Not blocking. When prints become possible: matched uncorrected/corrected chart set (ramps, shadow steps, skin tones, primaries, gradient, one photograph) at the printer's native raster, 3 repeats, same paper pack and settings, randomised order, neutral light, measured patches if an instrument is available; results in `Documentation/validation/`. Use it to confirm or revise the default intent/BPC and the print-path identity assumption.

## Working rules
1. Never modify user source images.
2. Do not claim colour accuracy from a build or a passing test; label evidence level.
3. Keep personal photographs and print outputs out of the repository unless cleared. The Farbenwerk profile at the root is an explicit owner-approved exception.
4. Do not iterate on hypotheses through CI one push at a time: reason first, batch diagnostics, then push.
5. Small, reviewable commits; README must match actual behaviour.
