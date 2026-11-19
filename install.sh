#!/bin/zsh
# Install ShotDock on a Mac.
#   curl -fsSL https://raw.githubusercontent.com/vastdreams/shotdock/main/install.sh | zsh
# Builds from source when Apple's compiler is present (no Gatekeeper prompt); otherwise downloads the latest
# release and installs it only if its Ed25519 signature matches the key below.
set -e
REPO="vastdreams/shotdock"
PUBKEY="lmqnIbdgGAmgZlIKcpqcYjl0+rxouShE5w2no/REP+w="
SRC="$HOME/Library/Application Support/ShotDock/src"
echo "ShotDock installer · © FSE Research and Investments"
[[ "$(uname)" == "Darwin" ]] || { echo "This installer is for macOS. Windows: see windows/README.md"; exit 1; }
mkdir -p "$HOME/Applications" "$HOME/.duraloop" "$HOME/Screenshots/sent"
if xcrun --find swiftc >/dev/null 2>&1; then
  echo "Building from source"
  rm -rf "$SRC"; mkdir -p "$SRC"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$SRC" --strip-components 1
  zsh "$SRC/build.sh"
  zsh "$SRC/scripts/install_launcher.sh"
else
  echo "Downloading the latest signed release"
  TMP=$(mktemp -d)
  URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | python3 -c 'import sys,json;a=json.load(sys.stdin)["assets"];print(next(x["browser_download_url"] for x in a if x["name"].endswith("-macos.zip")))')
  curl -fsSL -o "$TMP/s.zip" "$URL"; curl -fsSL -o "$TMP/s.sig" "$URL.sig"
  swift - "$TMP/s.zip" "$TMP/s.sig" "$PUBKEY" <<'SW' || { echo "Signature check FAILED. Nothing installed."; exit 1; }
import CryptoKit; import Foundation
let a = CommandLine.arguments
let zip = FileManager.default.contents(atPath: a[1])!, sig = Data(base64Encoded: try! String(contentsOfFile: a[2]).trimmingCharacters(in: .whitespacesAndNewlines))!
let key = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: a[3])!)
exit(key.isValidSignature(sig, for: Data(SHA256.hash(data: zip))) ? 0 : 1)
SW
  ditto -x -k "$TMP/s.zip" "$HOME/Applications"
  xattr -dr com.apple.quarantine "$HOME/Applications/ShotDock.app" 2>/dev/null || true
  echo "Signature verified."
fi
[[ -f "$HOME/.duraloop/config.json" ]] || echo '{"mode": "local", "claimcheck_provider": "deepseek", "claimcheck_model": "deepseek-chat", "claimcheck_exclude": []}' > "$HOME/.duraloop/config.json"
echo "Done. Open ShotDock Launcher, allow Screen Recording and Accessibility, then add your API key in ShotDock → ⋯ → Settings."
