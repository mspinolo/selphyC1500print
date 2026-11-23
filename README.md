# SELPHY CP1500 Print

A small native macOS utility for preparing JPEG copies with the Farbenwerk ICC profile and sending them to a Canon SELPHY CP1500.

> **Status: early development.** The repository is being initialized. No print or ICC-conversion workflow is considered validated until tested against the actual profile and printer.

## Goals

- Keep source photographs strictly read-only.
- Let the user choose JPEG files and a printer.
- Remember preferences between launches (including a security-scoped bookmark for the ICC profile).
- Create converted print copies in a private temporary directory.
- Submit print jobs through macOS printing services (CUPS).
- Remove temporary files after the job has completed or failed.
- Make color-management choices explicit and inspectable.

## Color-management notes

The CP1500 does not expose a user-selectable custom ICC output profile in its normal consumer printing workflow. Farbenwerk describes its CP1500 profile as a way to pre-adjust the image before printing, while the printer's own internal processing remains active.

That means this app must **not** blindly treat the Farbenwerk profile as an ordinary printer destination profile and then also allow an uncontrolled second conversion. The correct transform direction, rendering intent, output tagging and printer-driver settings must be established from the actual ICC profile and verified with test prints before enabling production printing.

The original JPEG is never a conversion target. All experiments and final processing operate on a copy.

## Planned implementation

1. Native SwiftUI macOS interface and persistent settings.
2. JPEG selection, image preview and profile inspection.
3. ColorSync-based ICC processing, enabled only after the profile workflow is validated.
4. Printer discovery and print submission through macOS.
5. Temporary-file lifecycle and failure-safe cleanup.

## Build

Requires macOS and Xcode with the Swift toolchain.

```sh
swift build
swift run
```

The first development milestone is a compilable UI/settings foundation. Printing and ICC conversion will be added in separately verifiable steps.

## Privacy and files

- Source JPEGs are not modified.
- ICC profiles are selected by the user; proprietary profile files are not included in this repository.
- Temporary print files are created outside the photo library and are removed after use.
