#!/usr/bin/env bash
# Creates a self-signed code-signing identity ("Pankapture Development") in the
# login keychain. Run once per machine.
#
# Why: macOS privacy permissions (Screen Recording, Microphone, Camera,
# Accessibility) are tied to the app's code signature. Ad-hoc signatures change
# with every build, so macOS would ask for permissions again after each
# rebuild. A stable self-signed identity keeps them granted.
#
# Not needed if you have an Apple Development / Developer ID certificate —
# pass it instead: PK_SIGN_IDENTITY="Apple Development: …" make app
set -euo pipefail

NAME="Pankapture Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✓ \"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

# Throwaway transport password; the identity lives in your login keychain.
openssl pkcs12 -export -name "$NAME" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:pankapture 2>/dev/null

# -T pre-authorises codesign so it can use the key without a prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P pankapture -T /usr/bin/codesign

echo "✓ Created \"$NAME\". Rebuild with: make app"
echo "  (It shows as untrusted in Keychain Access — that's expected and fine for local signing.)"
