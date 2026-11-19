#!/bin/zsh
# Create a local, self-signed code-signing identity "ShotDock Local Signing" in your login keychain.
# Builds signed with it keep the same identity, so macOS keeps Screen Recording / Accessibility permissions
# across rebuilds. Only for building on your own Mac; public releases are signed with a Developer ID.
set -e
ID="ShotDock Local Signing"
security find-identity -p codesigning | grep -q "$ID" && { echo "Already there: $ID"; exit 0; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -nodes -subj "/CN=$ID" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false"
P=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout "pass:$P" -legacy
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign
echo "Created: $ID"
