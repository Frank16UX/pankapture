#!/usr/bin/env bash
# Publishes a GitHub release with build/Pankapture.dmg attached.
#
#   scripts/release.sh            # tag v<CFBundleShortVersionString>
#
# Bump CFBundleShortVersionString (and CFBundleVersion) in Resources/Info.plist
# and commit before running. Needs the GitHub CLI (`gh auth login`).
#
# Releases must be signed with the stable "Pankapture Development" identity
# (ADR-8): users' privacy grants are tied to that signature, so an ad-hoc
# release would make every user re-grant Screen Recording after updating.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pankapture.app"
DMG="$ROOT/build/Pankapture.dmg"
IDENTITY="${PK_SIGN_IDENTITY:-Pankapture Development}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
TAG="v$VERSION"

command -v gh >/dev/null || { echo "✗ GitHub CLI not found (brew install gh)" >&2; exit 1; }
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "✗ Working tree has uncommitted changes; commit them first." >&2
  exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "✗ Release $TAG already exists. Bump CFBundleShortVersionString in Resources/Info.plist." >&2
  exit 1
fi
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "✗ Signing identity \"$IDENTITY\" not found. Releases must not be ad-hoc signed." >&2
  exit 1
fi

bash "$ROOT/scripts/package-dmg.sh"

AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ "$AUTHORITY" != "$IDENTITY" ]]; then
  echo "✗ App is signed by \"${AUTHORITY:-ad-hoc}\", expected \"$IDENTITY\"." >&2
  exit 1
fi

echo "▸ Publishing $TAG"
git -C "$ROOT" push origin HEAD
gh release create "$TAG" "$DMG" \
  --target "$(git -C "$ROOT" rev-parse HEAD)" \
  --title "Pankapture $VERSION" \
  --generate-notes

echo "✓ Released $TAG"
