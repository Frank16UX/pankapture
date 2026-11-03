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
# hdiutil's own size estimate for -srcfolder can come out too small for some
# app sizes, and create then fails; size the image from the staged folder with
# headroom instead. Not -quiet, so a failure says why. One retry covers a
# transient "Resource busy" on CI runners.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) * 12 / 10 + 20 ))
create_dmg() {
  hdiutil create -volname "Pankapture $VERSION" -srcfolder "$STAGE" -size "${SIZE_MB}m" \
    -fs HFS+ -format UDZO -ov "$DMG"
}
if ! create_dmg; then
  echo "⚠︎ hdiutil create failed; retrying in 5 s" >&2
  sleep 5
  create_dmg
fi
hdiutil verify -quiet "$DMG"

echo "✓ $DMG"
