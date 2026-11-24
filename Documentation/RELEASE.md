# Release process

`scripts/make-app.sh` builds `SELPHY CP1500 Print.app` from the SwiftPM executable
(Info.plist and entitlements are in `Packaging/`); `scripts/verify-app.sh` checks it.

## Sandbox and permissions
The app is sandboxed (`com.apple.security.app-sandbox`) and only reaches files the user
picks (`files.user-selected.read-write`). The ICC profile and the save folder are remembered
with security-scoped bookmarks, hence `files.bookmarks.app-scope`. No network access.

## Signing: ad-hoc only, no notarisation (owner decision)
There is no Developer ID and the app is not notarised. The CI signs ad-hoc
(`codesign --sign -`). Users must open it the first time with right-click → Open, or run
`xattr -dr com.apple.quarantine "SELPHY CP1500 Print.app"` after unzipping. This is stated in
every release's notes.

## Versioning
- `0.0.x`: pre-releases (marked as such on GitHub) while verification is incomplete.
- `1.0.0`: only when every item below is ticked.
- The version lives in `Packaging/Info.plist` (`CFBundleShortVersionString`); the release tag
  must be `v<version>` or the CI fails.

## How to release
1. Update `CHANGELOG.md` (a `## [x.y.z]` section is required: it becomes the release notes)
   and the version in `Packaging/Info.plist`; merge to `main` with green CI.
2. Either push the tag (`git tag vX.Y.Z && git push origin vX.Y.Z`) or run the workflow manually (Actions → macOS build → Run workflow, "release" ticked): the CI then creates the tag.
3. The workflow rebuilds, tests, verifies, and publishes the zip and its SHA-256 as a GitHub
   release (a pre-release for `0.x`).

## Checklist for 1.0.0 (proposed; the owner confirms or edits it)
- [ ] The owner has run the app on a real Mac: file pickers and bookmarks in the sandbox,
      remembered save folder after a restart, preview on the real display, performance.
- [ ] Remaining M2 validation-matrix gaps closed (real 16-bit/linear inputs, very large image
      timing, Display P3 source).
- [ ] M4: a print route works on a real CP1500 with the vendor's settings
      (`Documentation/PRINT_SETTINGS.md`).
- [ ] ColorChecker version known and its reference values used in the scanner check (owner to provide the version).
- [ ] Printer colour management confirmed off (the CP1500 only allows turning it off) and checked on a physical print.
- [ ] Track P: at least a first physical print comparison, or the "experimental, model-based"
      notice is kept in the app and README and 1.0.0 is explicitly declared without it.
- [ ] README/user documentation with limitations; app icon.

## Not present
- Notarisation and Developer ID signing; app icon.
