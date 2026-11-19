#!/bin/zsh
# Remove ShotDock. Keeps your shots and settings unless you pass --purge.
#   zsh uninstall.sh [--purge] [--id com.fseresearch.shotdock]
BUNDLE_ID="com.fseresearch.shotdock"; PURGE=""
while [[ $# -gt 0 ]]; do case $1 in --purge) PURGE=1; shift;; --id) BUNDLE_ID=$2; shift 2;; *) shift;; esac; done
pkill -f "$HOME/Applications/ShotDock Launcher.app/Contents/MacOS/ShotDockLauncher" 2>/dev/null
pkill -f "$HOME/Applications/ShotDock.app/Contents/MacOS/ShotDock" 2>/dev/null
pkill -f "$HOME/Library/Application Support/ShotDock/claimcheck/claimcheck.py" 2>/dev/null
# launchctl and tccutil act on the whole user account, so only run them for the real home folder (not a test HOME).
REAL_HOME=$(dscl . -read "/Users/$USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
SYSTEM=""; [[ "$HOME" == "$REAL_HOME" ]] && SYSTEM=1
[[ -n "$SYSTEM" ]] && launchctl remove "$BUNDLE_ID.launcher" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.launcher.plist"
rm -rf "$HOME/Applications/ShotDock.app" "$HOME/Applications/ShotDock Launcher.app"
# Forget the permissions macOS granted, so nothing stale is left in System Settings.
if [[ -n "$SYSTEM" ]]; then
  tccutil reset ScreenCapture "$BUNDLE_ID.launcher" >/dev/null 2>&1
  tccutil reset Accessibility "$BUNDLE_ID.launcher" >/dev/null 2>&1
fi
if [[ -n "$PURGE" ]]; then
  rm -rf "$HOME/Library/Application Support/ShotDock" "$HOME/.duraloop" "$HOME/Screenshots/sent"
  [[ -n "$SYSTEM" ]] && for a in deepseek anthropic openai duraloop-ingest; do security delete-generic-password -s shotdock -a $a >/dev/null 2>&1; done
fi
echo "ShotDock removed.${PURGE:+ Settings, keys and saved shots were removed too.}"
echo "Kept: your editor settings (the checklist saved backups named <file>.shotdock-backup-<time> next to each file it changed),"
echo "the screenshot hook ~/.claude/hooks/attach_screenshots.py, and ~/.duraloop and ~/Screenshots/sent unless you used --purge."
