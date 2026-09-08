#!/bin/bash
# Build a copy of Ledge that this Mac has never seen before.
#
# Testing the first-run experience needs a machine with no grants and no
# preferences. Wiping is supposed to give that, and does not: `tccutil reset`
# is a silent no-op here even under sudo, and permission rows granted weeks ago
# survive it. System Settings then shows switches already on for an app the
# tester is pretending to have just installed.
#
# macOS keys both TCC grants and the preferences domain to the *bundle
# identifier*. An identifier it has never seen has no grants, no preferences,
# no Launch Services history and no login item — which is exactly a fresh
# user's Mac, without touching the real app's state or the tester's own.
#
# So this takes the built bundle, gives it its own identifier and name,
# re-signs it under the same Developer ID (the signature a downloader gets),
# and installs it alongside. Throw it away with `rm -rf` when finished; nothing
# it did is shared with the real app.
#
# usage: Scripts/fresh-copy.sh [suffix]     (default suffix: fresh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUFFIX="${1:-fresh}"
SOURCE="${LEDGE_DIST_APP:-$HOME/Library/Developer/Ledge/dist/Ledge.app}"
BUNDLE_ID="com.egemert.ledge.$SUFFIX"
NAME="Ledge $(tr '[:lower:]' '[:upper:]' <<< "${SUFFIX:0:1}")${SUFFIX:1}"
TARGET="/Applications/$NAME.app"

[[ -d "$SOURCE" ]] || { echo "no built app at $SOURCE — run 'make release' first" >&2; exit 1; }

IDENTITY=$(security find-identity -v -p codesigning |
    grep -m1 "Developer ID Application" | awk '{print $2}')
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }

rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

PLIST="$TARGET/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleName $NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleDisplayName $NAME" "$PLIST" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add CFBundleDisplayName string $NAME" "$PLIST"

# No self-updating: an update would replace this copy with the real app, which
# is both confusing mid-test and a way to lose the identifier being tested.
for key in SUFeedURL SUEnableAutomaticChecks SUPublicEDKey; do
    /usr/libexec/PlistBuddy -c "Delete $key" "$PLIST" 2>/dev/null || true
done

xattr -cr "$TARGET"

# The adapter is dlopened by perl and carries its own identifier; it must not
# claim the real app's.
shopt -s nullglob
for dylib in "$TARGET"/Contents/Frameworks/*.dylib; do
    codesign --force --timestamp=none \
        --identifier "$BUNDLE_ID.mediaadapter" \
        --sign "$IDENTITY" "$dylib" >/dev/null
done
shopt -u nullglob

# Outer bundle only: nested Sparkle code keeps the signature it already has.
codesign --force --timestamp=none \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$ROOT/Bundle/Ledge.entitlements" \
    --sign "$IDENTITY" "$TARGET" >/dev/null

codesign --verify --strict "$TARGET"
echo "$NAME installed at $TARGET"
echo "identifier: $BUNDLE_ID"
codesign -d -r- "$TARGET" 2>&1 | tail -1
echo
echo "open it with:  open \"$TARGET\""
echo "remove it with: rm -rf \"$TARGET\" && defaults delete $BUNDLE_ID"
