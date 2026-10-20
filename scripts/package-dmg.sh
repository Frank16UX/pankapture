#!/usr/bin/env bash
# Builds the release .app and wraps it in a drag-to-Applications disk image.
#
#   scripts/package-dmg.sh              # → build/Pankapture.dmg
#   SKIP_BUILD=1 scripts/package-dmg.sh # reuse an existing build/Pankapture.app
#
# The image name has no version so the "latest release" download URL stays
# stable for scripts/install.sh. The version lives in the app's Info.plist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pankapture.app"
DMG="$ROOT/build/Pankapture.dmg"

if [[ -z "${SKIP_BUILD:-}" ]]; then
  bash "$ROOT/scripts/bundle.sh"
fi
[[ -d "$APP" ]] || { echo "✗ $APP not found" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "▸ Staging disk image ($VERSION)"
# ditto keeps the code signature and extended attributes intact.
ditto "$APP" "$STAGE/Pankapture.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Pankapture $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

echo "✓ $DMG"
