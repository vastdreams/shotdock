#!/bin/zsh
# Sign the packaged app with the stable local identity "ShotDock Local Signing" so macOS keeps Screen Recording /
# Accessibility permissions across rebuilds (permissions are tied to the signature, and an unsigned or ad-hoc
# build gets a new one every time). For releases use a Developer ID instead (npm run dist:mac).
set -e
APP="${1:-release/mac-arm64/ShotDock.app}"
ID="ShotDock Local Signing"
security find-identity -p codesigning | grep -q "$ID" || { echo "Missing identity '$ID'. See docs/SETUP.md."; exit 1; }
# Inside out: helpers and binaries first, then frameworks, then the app.
find "$APP/Contents" \( -name "*.dylib" -o -name "*.node" -o -perm +111 -type f \) -not -path "*/Resources/*.lproj/*" -print0 \
  | xargs -0 -I{} codesign --force --sign "$ID" --timestamp=none "{}" 2>/dev/null || true
for f in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Frameworks/*.app; do codesign --force --sign "$ID" --timestamp=none "$f"; done
codesign --force --sign "$ID" --timestamp=none --identifier com.fseresearch.shotdock "$APP"
codesign --verify --deep "$APP" && echo "signed: $APP"
