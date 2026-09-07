#!/bin/bash
# Notarize the release build and produce the final, stapled DMG.
#
# usage: notarize.sh <app-path> <dmg-path> [identity]
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the keychain
#      (paid Apple Developer Program membership).
#   2. Stored notarization credentials:
#        xcrun notarytool store-credentials notary \
#            --apple-id <apple-id-email> --team-id <TEAMID> \
#            --password <app-specific-password from appleid.apple.com>
#
# Flow: the app is notarized and stapled first, THEN packed into the DMG, and
# the DMG is notarized and stapled too. Stapling both means Gatekeeper passes
# even on a Mac that is offline at first launch.
set -euo pipefail

APP="${1:?app path required}"
DMG="${2:?dmg path required}"
IDENTITY="${3:--}"
PROFILE="${LEDGE_NOTARY_PROFILE:-notary}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run 'make release' first" >&2
    exit 1
fi

# Captured first: `grep -q` closes the pipe on its first match, codesign gets
# SIGPIPE, and under pipefail the whole test reads as a failure.
SIGNATURE="$(codesign -dvv "$APP" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGNATURE"; then
    echo "error: $APP is not signed with a Developer ID Application identity." >&2
    echo "       Apple only notarizes Developer ID-signed code. Create the" >&2
    echo "       certificate (Xcode → Settings → Accounts → Manage Certificates" >&2
    echo "       → + → Developer ID Application), then re-run 'make release'." >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "error: no notarization credentials under profile \"$PROFILE\"." >&2
    echo "       Store them once with:" >&2
    echo "         xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "             --apple-id <email> --team-id <TEAMID> --password <app-specific>" >&2
    exit 1
fi

WORK="$(mktemp -d -t ledge-notarize)"
trap 'rm -rf "$WORK"' EXIT

# 1. Notarize the app (as a zip — notarytool takes zip/dmg/pkg, not bare .app).
ZIP="$WORK/Ledge.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "submitting app for notarization (usually 1-5 minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# 2. Staple the ticket onto the app itself.
xcrun stapler staple "$APP"

# 3. Build the DMG from the stapled app, then notarize and staple that too.
#    dmg.sh refuses to overwrite a stapled image, so a previous run's output is
#    cleared here first — this script is the one place that may replace it.
rm -f "$DMG"
"$ROOT/Scripts/dmg.sh" "$APP" "$DMG" "$IDENTITY"
echo "submitting DMG for notarization..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 4. Prove the result is what a downloader's Gatekeeper will see.
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"

echo "notarized and stapled: $DMG"
