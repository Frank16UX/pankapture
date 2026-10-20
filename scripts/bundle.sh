#!/usr/bin/env bash
# Builds Pankapture with SwiftPM and wraps it into a signed .app bundle.
#
#   scripts/bundle.sh                 # release build → build/Pankapture.app
#   CONFIG=debug scripts/bundle.sh    # debug build
#   PK_SIGN_IDENTITY="…" scripts/bundle.sh
#
# Signing: uses the stable local identity created by scripts/create-dev-cert.sh
# when present. A stable identity matters — macOS ties Screen Recording and
# other privacy grants to the code signature, so ad-hoc builds lose their
# permissions on every rebuild.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pankapture.app"
IDENTITY="${PK_SIGN_IDENTITY:-Pankapture Development}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --arch arm64 --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --package-path "$ROOT" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pankapture" "$APP/Contents/MacOS/Pankapture"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# SwiftPM resource bundles (none yet; future targets with resources).
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "⚠︎ Signing identity \"$IDENTITY\" not found — using ad-hoc signing."
  echo "  Privacy permissions will reset on every rebuild. Run: make cert"
fi

echo "▸ Signing with: $SIGN"
codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT/Resources/Pankapture.entitlements" \
  --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP"
