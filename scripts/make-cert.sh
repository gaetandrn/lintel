#!/usr/bin/env bash
# Create the self-signed "Lintel Local" code signing identity, once, in Lintel's own keychain.
# A stable signature keeps the Accessibility permission across builds; an ad-hoc
# signature changes every time and macOS revokes the permission.
# install.sh has its own copy of this, since it must work without the repository.
set -euo pipefail

NAME="Lintel Local"
SUPPORT="$HOME/Library/Application Support/Lintel"
SIGNING="$SUPPORT/signing"
KEYCHAIN="$SUPPORT/signing.keychain-db"
PASSWORD="$SUPPORT/signing.password"

hashes() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null |
    awk -v name="\"$NAME\"" 'index($0, name) { print $2 }' | sort -u
}

if [ -f "$SIGNING" ] && [ -f "$PASSWORD" ] && [ "$(hashes)" = "$(cat "$SIGNING")" ]; then
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/identity.p12" -passout "pass:$pass" -name "$NAME"
rm -f "$tmp/key.pem"

mkdir -p "$SUPPORT"
security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
keychain_pass=$(/usr/bin/openssl rand -hex 24)
(umask 077 && printf '%s\n' "$keychain_pass" >"$PASSWORD")
security create-keychain -p "$keychain_pass" "$KEYCHAIN"
# codesign may use the key without asking; -x keeps the private key from being exported.
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign -x >/dev/null
hashes >"$SIGNING"
security lock-keychain "$KEYCHAIN" 2>/dev/null || true
echo "==> Created the \"$NAME\" signing identity"
