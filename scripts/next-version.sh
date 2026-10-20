#!/usr/bin/env bash
# Prints the version the next release gets.
#
# Patch releases are automatic: one more than the newest v* tag (0.2.3 → 0.2.4).
# For a minor or major release, raise CFBundleShortVersionString in
# Resources/Info.plist (e.g. to 0.3.0); when it's higher than the newest tag,
# it's used as is.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
LATEST="$(git -C "$ROOT" tag -l 'v[0-9]*' | sed 's/^v//' | sort -V | tail -1)"

if [[ -z "$LATEST" ]]; then
  echo "$BASE"
  exit 0
fi
# The higher of the two; a tie means BASE was already released.
if [[ "$BASE" != "$LATEST" && "$(printf '%s\n%s\n' "$BASE" "$LATEST" | sort -V | tail -1)" == "$BASE" ]]; then
  echo "$BASE"
else
  IFS=. read -r MAJOR MINOR PATCH <<< "$LATEST"
  echo "$MAJOR.${MINOR:-0}.$(( ${PATCH:-0} + 1 ))"
fi
