#!/usr/bin/env bash
# Installs (or updates) Pankapture from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/Frank16UX/pankapture/main/scripts/install.sh | bash
#
# Options (environment):
#   PANKAPTURE_VERSION=v0.1.0   install a specific release instead of the latest
#   PANKAPTURE_DIR=~/Applications   install somewhere other than /Applications
#
# Files downloaded with curl aren't quarantined, so the app opens without the
# Gatekeeper "unidentified developer" prompt the DMG gets from a browser.
set -euo pipefail

REPO="Frank16UX/pankapture"
DEST_DIR="${PANKAPTURE_DIR:-/Applications}"
DEST="$DEST_DIR/Pankapture.app"

if [[ -n "${PANKAPTURE_VERSION:-}" ]]; then
  URL="https://github.com/$REPO/releases/download/$PANKAPTURE_VERSION/Pankapture.dmg"
else
  URL="https://github.com/$REPO/releases/latest/download/Pankapture.dmg"
fi

say()  { printf '\033[1m▸ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Pankapture is a macOS app."
[[ "$(uname -m)" == "arm64" ]]  || fail "Pankapture needs an Apple Silicon Mac."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MAJOR >= 15 )) || fail "Pankapture needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."

TMP="$(mktemp -d)"
MOUNT="$TMP/mount"
cleanup() {
  hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

say "Downloading $URL"
curl -fL --progress-bar -o "$TMP/Pankapture.dmg" "$URL" || fail "Download failed. Is there a published release?"

mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$TMP/Pankapture.dmg"
[[ -d "$MOUNT/Pankapture.app" ]] || fail "The disk image doesn't contain Pankapture.app."

if pgrep -xq Pankapture; then
  say "Quitting the running Pankapture"
  osascript -e 'tell application id "com.franklinperez.Pankapture" to quit' 2>/dev/null || true
  for _ in {1..20}; do pgrep -xq Pankapture || break; sleep 0.25; done
  pkill -x Pankapture 2>/dev/null || true
fi

SUDO=""
mkdir -p "$DEST_DIR" 2>/dev/null || true
if [[ ! -w "$DEST_DIR" ]] || { [[ -e "$DEST" ]] && [[ ! -w "$DEST" ]]; }; then
  say "Administrator password needed to write to $DEST_DIR"
  SUDO="sudo"
fi

say "Installing to $DEST"
$SUDO rm -rf "$DEST"
$SUDO ditto "$MOUNT/Pankapture.app" "$DEST"
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
printf '\033[32m✓ Pankapture %s installed.\033[0m Look for the viewfinder icon in the menu bar.\n' "$VERSION"
open "$DEST"
