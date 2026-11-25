#!/bin/bash
# Checks a bundle built by make-app.sh: plist, signature, sandbox entitlements.
# Usage: scripts/verify-app.sh "<path to .app>"
set -euo pipefail
app="$1"
plutil -lint "$app/Contents/Info.plist"
icon=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$app/Contents/Info.plist")
[ -s "$app/Contents/Resources/$icon.icns" ] || { echo "::error::missing icon $icon.icns"; exit 1; }
sips -g pixelWidth "$app/Contents/Resources/$icon.icns" >/dev/null || { echo "::error::unreadable icon"; exit 1; }
[ -s "$app/Contents/Resources/Credits.rtf" ] || { echo "::error::missing Credits.rtf"; exit 1; }
grep -q "Permission is hereby granted" "$app/Contents/Resources/Licenses/LittleCMS-LICENSE.txt" \
  || { echo "::error::missing LittleCMS licence text"; exit 1; }
codesign --verify --strict --deep "$app"
ent=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || codesign -d --entitlements :- "$app")
for k in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope com.apple.security.print; do
  echo "$ent" | grep -q "$k" || { echo "::error::missing entitlement $k"; exit 1; }
done
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist"
