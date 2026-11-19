#!/bin/zsh
# Install ShotDock on a Mac. Safe to run again: it updates in place and never touches another install.
#
#   curl -fsSL https://raw.githubusercontent.com/vastdreams/shotdock/main/install.sh | zsh
#
# Options (environment variables):
#   SHOTDOCK_SRC=/path/to/checkout   install from a local copy instead of downloading
#   SHOTDOCK_NO_LAUNCH=1             install files only; start nothing (for tests and agents)
set -e
REPO="vastdreams/shotdock"
BUNDLE_ID="com.fseresearch.shotdock"
SUPPORT="$HOME/Library/Application Support/ShotDock"
say() { print -P "%B▸%b $1"; }
fail() { print -P "%F{red}✗ $1%f"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "This installer is for macOS. Windows: see windows/README.md."
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 13 ]] || fail "ShotDock needs macOS 13 or later."

# Never overwrite a different ShotDock install (for example a development build with another identifier).
EXISTING="$HOME/Applications/ShotDock.app"
if [[ -d "$EXISTING" ]]; then
  OTHER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$EXISTING/Contents/Info.plist" 2>/dev/null || true)
  [[ -z "$OTHER" || "$OTHER" == "$BUNDLE_ID" ]] || fail "Another ShotDock ($OTHER) is installed. Remove it first: zsh uninstall.sh --id $OTHER"
fi

mkdir -p "$HOME/Applications" "$HOME/.duraloop" "$HOME/Screenshots/sent" "$SUPPORT" "$HOME/.claude/hooks"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  say "ShotDock builds on your Mac with Apple's free command line tools, which are not installed yet."
  xcode-select --install 2>/dev/null || true
  fail "Click Install in the window Apple just opened (about 5 minutes), then run this installer again."
fi

if [[ -n "$SHOTDOCK_SRC" ]]; then
  SRC="$SHOTDOCK_SRC"; say "Using local source $SRC"
else
  SRC="$SUPPORT/src"; rm -rf "$SRC"; mkdir -p "$SRC"
  say "Downloading source"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$SRC" --strip-components 1
fi

say "Building ShotDock (about a minute)"
BUNDLE_ID=$BUNDLE_ID zsh "$SRC/build.sh"
say "Building ShotDock Launcher"
SHOTDOCK_NO_LAUNCH=${SHOTDOCK_NO_LAUNCH:-} BUNDLE_ID=$BUNDLE_ID zsh "$SRC/scripts/install_launcher.sh"
cp -R "$SRC/claimcheck" "$SUPPORT/"
cp "$SRC/hooks/attach_screenshots.py" "$HOME/.claude/hooks/"
cp "$SRC/uninstall.sh" "$SUPPORT/uninstall.sh"

[[ -f "$HOME/.duraloop/config.json" ]] || echo '{"mode": "local", "claimcheck_provider": "deepseek", "claimcheck_model": "deepseek-chat", "claimcheck_exclude": []}' > "$HOME/.duraloop/config.json"

if [[ -z "$SHOTDOCK_NO_LAUNCH" ]]; then
  say "Starting ShotDock. A checklist opens: click each Fix button until everything is green."
  open -a "$HOME/Applications/ShotDock Launcher.app"
fi
print -P "%F{green}✓ ShotDock installed.%f"
echo "  Check:  ~/Applications/ShotDock.app/Contents/MacOS/ShotDock --doctor"
echo "  Remove: zsh ~/Library/Application\ Support/ShotDock/uninstall.sh"
