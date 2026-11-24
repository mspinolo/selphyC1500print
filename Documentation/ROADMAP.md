# Project roadmap (v2)

Working plan for `selphyC1500print`. The repository is the source of truth; update this file whenever a task is completed, deferred or blocked. Every item is labelled by evidence level: **implemented** (code exists), **tested** (automated test passes in CI), **validated** (confirmed on physical prints).

## Goal

A native macOS utility that pre-corrects photos for the Canon SELPHY CP1500 using the Farbenwerk CP1500 ICC profile, with a transparent, reproducible colour pipeline and safe handling of originals. The colour model is **trusted per vendor** (Farbenwerk profile plus the vendor's printer-setting instructions), not yet validated on physical prints; the app stays labelled experimental until the optional physical track (P) is done.

## Where the project actually stands (2026-11-24)

- Implemented: SwiftUI shell, ICC header/tag inspector, ColorSync pre-correction (source RGB -> PCS -> printer B2A, result tagged sRGB), batch export to a temporary folder, read-only treatment of originals.
- Tested: CI builds and runs 18 tests. The only failures (5 assertions) were in `testColorSyncMatchesIndependentLittleCMSReference` (raw RGB codes, ColorSync vs LittleCMS); they are now tracked as strict expected failures with unchanged thresholds (see Findings).
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
- [ ] Pin and record macOS / Xcode / Swift versions (CI prints them); cache Homebrew; make the app build independent of the LittleCMS oracle where possible.
- [x] Known ColorSync/LittleCMS divergences recorded as strict expected failures (thresholds unchanged, still reported, test fails if they start passing); CI publishes test numbers as annotations. Replaced by the DeltaE metric in M1.
- [ ] Remove or clearly label unused assets (the 6 MB third-party TIFF is referenced by no test; confirm its licence).

**Exit:** green CI on a clean checkout; docs match reality.

### M1 - Colour engine decision
- [ ] Build the DeltaE00 harness (Lab via printer A2B, in-gamut and out-of-gamut reported separately).
- [ ] Resolve the BPC discrepancy by data: per-patch dump, v4 forced-BPC hypothesis, which entry of the ColorSync sequence carries BPC.
- [ ] Decide ColorSync vs LittleCMS using the gate in Decision 3; document the choice.

**Exit:** one production engine, documented BPC semantics, DeltaE00 tolerances recorded.

### M2 - Pipeline hardening
- [ ] 16-bit internal processing with a single final rounding; lossless (or 4:4:4, q=100) output; correct output resolution metadata.
- [ ] Source handling: embedded Adobe RGB / Display P3 / untagged (explicit sRGB assumption surfaced in UI), grayscale and CMYK (convert or reject clearly), EXIF orientation 1-8, alpha, large images, memory bounds.
- [ ] Tests for every case in the validation matrix, using small deterministic fixtures; fix the 3-byte packing loops (performance) or replace them.

**Exit:** the validation matrix in `VALIDATION_PLAN.md` is fully automated and green.

### M3 - Real application
- [ ] Proper `.app` bundle (Xcode project or build script), Info.plist, sandbox entitlements consistent with the security-scoped bookmarks, optional signing/notarisation, CI artifact.
- [ ] Before/after preview; export to a user-chosen folder instead of a hidden temp folder; progress and cancellation; clear errors.
- [ ] Decide input scope (JPEG only vs HEIC/TIFF) and UI language.

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
