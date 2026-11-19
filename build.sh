#!/bin/zsh
# Build ShotDock into ~/Applications/ShotDock.app.
#   BUNDLE_ID   app identifier (default com.fseresearch.shotdock)
#   VERSION     shown in About and used by updates (default from VERSION file)
set -e
cd "${0:A:h}/app/src"
BUNDLE_ID=${BUNDLE_ID:-com.fseresearch.shotdock}
VERSION=${VERSION:-$(cat ../../VERSION)}
UPDATE_REPO=${UPDATE_REPO:-vastdreams/shotdock}
UPDATE_KEY=${UPDATE_KEY:-lmqnIbdgGAmgZlIKcpqcYjl0+rxouShE5w2no/REP+w=}
OUT=${OUT:-$HOME/Applications}
BIN=$(mktemp -d)/ShotDock
swiftc -O -o "$BIN" main.swift Shared.swift Picker.swift Composer.swift Sender.swift Checks.swift Chats.swift Hub.swift \
  Markup.swift Media.swift Prefs.swift Capture.swift Settings.swift Updater.swift Onboarding.swift App.swift \
  -framework Cocoa -framework Carbon -framework Vision -framework AVFoundation -framework CoreImage -framework CryptoKit -framework Security 2>"${TMPDIR:-/tmp}/shotdock-build.log" || { cat "${TMPDIR:-/tmp}/shotdock-build.log"; exit 1; }
A="$OUT/ShotDock.app/Contents"; mkdir -p "$A/MacOS"; cp "$BIN" "$A/MacOS/ShotDock"
cat > "$A/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string><key>CFBundleName</key><string>ShotDock</string>
<key>CFBundleExecutable</key><string>ShotDock</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string><key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHumanReadableCopyright</key><string>© 2026 FSE Research and Investments</string>
<key>ShotDockUpdateRepo</key><string>$UPDATE_REPO</string><key>ShotDockUpdateKey</key><string>$UPDATE_KEY</string>
</dict></plist>
PL
codesign --force -s - --identifier "$BUNDLE_ID" "$OUT/ShotDock.app" >/dev/null 2>&1
echo "Built $OUT/ShotDock.app $VERSION"
