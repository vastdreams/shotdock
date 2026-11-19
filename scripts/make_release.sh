#!/bin/zsh
# Publisher only: build, zip, sign with the Keychain key from keygen.swift, and publish a GitHub release.
#   scripts/make_release.sh 1.0.1
set -e
V=$1; [[ -n "$V" ]] || { echo "usage: make_release.sh <version>"; exit 1; }
R="${0:A:h}/.."; echo "$V" > "$R/VERSION"
OUT=$(mktemp -d) VERSION=$V zsh "$R/build.sh"
Z="$R/dist/ShotDock-$V-macos.zip"; mkdir -p "$R/dist"
ditto -c -k --keepParent "$OUT/ShotDock.app" "$Z"
swift "$R/scripts/sign.swift" "$Z" > "$Z.sig"
shasum -a 256 "$Z" > "$Z.sha256"
gh release create "v$V" "$Z" "$Z.sig" "$Z.sha256" --title "ShotDock $V" --notes "Signed release. Installs only if the Ed25519 signature verifies."
