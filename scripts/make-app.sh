#!/bin/bash
# Builds "SELPHY CP1500 Print.app" from the SwiftPM executable.
# Usage: scripts/make-app.sh [output-dir]      (default: build-app)
# Env:   SIGN_IDENTITY  codesign identity; "-" (default) = ad-hoc signature.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/build-app}"
identity="${SIGN_IDENTITY:--}"
app="$out/SELPHY CP1500 Print.app"

cd "$root"
swift build -c release
bin="$(swift build -c release --show-bin-path)/SELPHYCP1500Print"
[ -x "$bin" ] || { echo "executable not found: $bin" >&2; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/SELPHYCP1500Print"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# About window credits, and the full licence text of the vendored LittleCMS (MIT: the notice must
# accompany every copy).
cp Packaging/Credits.rtf "$app/Contents/Resources/Credits.rtf"
mkdir -p "$app/Contents/Resources/Licenses"
cp Sources/CLittleCMS/LICENSE "$app/Contents/Resources/Licenses/LittleCMS-LICENSE.txt"
# The test pictures of the validation assistant (rendered by scripts/make-test-photos.py).
mkdir -p "$app/Contents/Resources/TestPhotos"
cp Packaging/TestPhotos/*.png "$app/Contents/Resources/TestPhotos/"
printf 'APPL????' > "$app/Contents/PkgInfo"
plutil -lint "$app/Contents/Info.plist"

# Hardened runtime is required for notarisation; harmless for ad-hoc signing.
codesign --force --options runtime --timestamp=none \
  --entitlements Packaging/SELPHYCP1500Print.entitlements \
  --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
echo "$app"
