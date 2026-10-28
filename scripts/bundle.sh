#!/usr/bin/env bash
# Builds Pankapture with SwiftPM and wraps it into a signed .app bundle.
#
#   scripts/bundle.sh                 # release build → build/Pankapture.app
#   CONFIG=debug scripts/bundle.sh    # debug build
#   PK_SIGN_IDENTITY="…" scripts/bundle.sh
#   PK_VERSION=0.2.4 PK_BUILD=57 scripts/bundle.sh   # a release build
#
# PK_VERSION stamps CFBundleShortVersionString and marks the bundle as a
# release build (PKReleaseBuild), which lets it install updates of itself.
# Local builds keep Info.plist's version and only check for updates.
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
# SwiftPM records the deployment target as the binary's SDK version, so macOS
# would run the app in its macOS 15 compatibility appearance: legacy toolbars
# and split views, plus glitches like an empty, unseparated toolbar area over
# inspectors. Record the SDK it was actually built with (ADR-46).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_VERSION="$(otool -l "$APP/Contents/MacOS/Pankapture" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
xcrun vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/Pankapture.stamped" "$APP/Contents/MacOS/Pankapture" 2>/dev/null
mv "$APP/Contents/MacOS/Pankapture.stamped" "$APP/Contents/MacOS/Pankapture"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${PK_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PK_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PKReleaseBuild bool true" "$APP/Contents/Info.plist"
fi
if [[ -n "${PK_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PK_BUILD" "$APP/Contents/Info.plist"
fi
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
