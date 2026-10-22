#!/bin/bash
# Creates a local self-signed code-signing identity so TCC (Screen Recording,
# Local Network, Input Monitoring) survives rebuilds.
#
# Why: ad-hoc signing ("-") produces a new cdhash every build, so macOS treats
# each build as a brand-new app and forgets every permission. A named identity
# keys TCC to (bundle id + signing identity), which is stable across builds.
#
# One-time setup; needs no Apple Developer account. Run from the login GUI (the
# keychain must be unlocked so `security import` can write).
set -euo pipefail

NAME="${1:-BoltKVM Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity \"$NAME\" already present:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

echo "==> generating self-signed code-signing certificate \"$NAME\""
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# The p12 password only protects the temporary file; macOS rejects an empty
# one ("MAC verification failed"), so use a throwaway value.
P12PASS="boltkvm-local"
openssl pkcs12 -export -legacy -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$P12PASS" 2>/dev/null \
  || openssl pkcs12 -export -out "$WORK/identity.p12" \
     -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$P12PASS"

echo "==> importing into login keychain (may ask for your password once)"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> trusting it for code signing (user domain, no admin needed)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" || {
  echo "identity not visible to codesign yet — unlock the keychain and re-run" >&2
  exit 1
}
cat <<TIP

Done. Build with:

  BOLTKVM_CODESIGN_IDENTITY="$NAME" ./Packaging/build-app.sh

If codesign later prompts for keychain access, choose "Always Allow" once.
TIP
