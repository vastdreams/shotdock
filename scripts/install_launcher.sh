#!/bin/zsh
# Build the small launcher that holds macOS permissions and keeps ShotDock running, and start it at login.
set -e
cd "${0:A:h}/../app/launcher"
BUNDLE_ID=${BUNDLE_ID:-com.fseresearch.shotdock}
LB=$(mktemp -d)/ShotDockLauncher
swiftc -O -o "$LB" main.swift -framework Cocoa -framework ApplicationServices 2>/dev/null
A="$HOME/Applications/ShotDock Launcher.app/Contents"; mkdir -p "$A/MacOS"; cp "$LB" "$A/MacOS/ShotDockLauncher"
cat > "$A/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$BUNDLE_ID.launcher</string>
<key>CFBundleName</key><string>ShotDock Launcher</string><key>CFBundleExecutable</key><string>ShotDockLauncher</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>ShotDock captures the area or element you pick and sends it to your chat.</string></dict></plist>
PL
codesign --force -s - --identifier "$BUNDLE_ID.launcher" "$HOME/Applications/ShotDock Launcher.app" 2>/dev/null
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/$BUNDLE_ID.launcher.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$BUNDLE_ID.launcher</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$HOME/Applications/ShotDock Launcher.app</string></array>
<key>RunAtLoad</key><true/></dict></plist>
PL
[[ -n "$SHOTDOCK_NO_LAUNCH" ]] || open -a "$HOME/Applications/ShotDock Launcher.app"
