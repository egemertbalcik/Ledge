#!/bin/bash
# Build a drag-to-install DMG: the app on the left, /Applications on the right.
#
# usage: dmg.sh <app-path> <dmg-path> [identity]
#
# The DMG itself gets signed when a real identity is given — Gatekeeper treats
# an unsigned disk image as unidentified even when the app inside is fine.
set -euo pipefail

APP="${1:?app path required}"
DMG="${2:?dmg path required}"
IDENTITY="${3:--}"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run 'make release' first" >&2
    exit 1
fi

STAGING="$(mktemp -d -t ledge-dmg)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Detritus on the staged copy would survive into the image.
xattr -cr "$STAGING"

# A DMG that already carries a notarization ticket is the shipped artifact;
# quietly replacing it with an unnotarized one is how a bad upload happens.
# notarize.sh removes its own previous output before calling in here.
if [[ -f "$DMG" ]] && xcrun stapler validate -q "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG is already notarized and stapled — refusing to overwrite it." >&2
    echo "       Delete it by hand if a rebuild is really intended." >&2
    exit 1
fi

rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
hdiutil create -volname "Ledge" -srcfolder "$STAGING" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -quiet "$DMG"

if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    echo "signed $(basename "$DMG")"
else
    echo "warning: DMG left unsigned (no identity)" >&2
fi

echo "created $DMG"
