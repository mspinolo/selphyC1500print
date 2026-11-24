#!/bin/bash
# Checks a bundle built by make-app.sh: plist, signature, sandbox entitlements.
# Usage: scripts/verify-app.sh "<path to .app>"
set -euo pipefail
app="$1"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --strict --deep "$app"
ent=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || codesign -d --entitlements :- "$app")
for k in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope; do
  echo "$ent" | grep -q "$k" || { echo "::error::missing entitlement $k"; exit 1; }
done
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist"
