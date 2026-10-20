#!/usr/bin/env bash
# Publishes a GitHub release with build/Pankapture.dmg attached.
#
#   scripts/release.sh
#
# The "Release" GitHub workflow runs this on every merge to main
# (.github/workflows/release.yml); you can also run it from your Mac.
# The version comes from scripts/next-version.sh. Needs the GitHub CLI.
#
# Releases must be signed with the stable "Pankapture Development" identity
# (ADR-8): users' privacy grants are tied to that signature, so a release
# signed any other way would make every user re-grant Screen Recording, and
# the in-app updater refuses it (ADR-28).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pankapture.app"
DMG="$ROOT/build/Pankapture.dmg"
IDENTITY="${PK_SIGN_IDENTITY:-Pankapture Development}"
# SHA-1 of the "Pankapture Development" certificate every release is signed with.
CERT_SHA1="${PK_CERT_SHA1:-6E2DE4497632596C22B67EECA7209FF8B8448206}"

command -v gh >/dev/null || { echo "✗ GitHub CLI not found (brew install gh)" >&2; exit 1; }
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
  echo "✗ Working tree has uncommitted changes; commit them first." >&2
  exit 1
fi

VERSION="${PK_VERSION:-$(bash "$ROOT/scripts/next-version.sh")}"
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "✗ Release $TAG already exists." >&2
  exit 1
fi
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "✗ Signing identity \"$IDENTITY\" not found. Releases must not be ad-hoc signed." >&2
  exit 1
fi

PK_VERSION="$VERSION" PK_BUILD="${PK_BUILD:-$(git -C "$ROOT" rev-list --count HEAD)}" \
  bash "$ROOT/scripts/package-dmg.sh"

LEAF="$(codesign -dr - "$APP" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p' | tr '[:lower:]' '[:upper:]')"
if [[ "$LEAF" != "$CERT_SHA1" ]]; then
  echo "✗ App is signed by certificate ${LEAF:-ad-hoc}, expected $CERT_SHA1." >&2
  exit 1
fi

echo "▸ Publishing $TAG"
gh release create "$TAG" "$DMG" \
  --target "$(git -C "$ROOT" rev-parse HEAD)" \
  --title "Pankapture $VERSION" \
  --generate-notes

echo "✓ Released $TAG"
