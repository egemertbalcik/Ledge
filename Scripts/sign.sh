#!/bin/bash
# Code-sign the bundle.
#
# Signing identity is load-bearing for developer velocity, not a formality.
# TCC keys permission grants to the code signature. With a real Apple
# Development identity the designated requirement is stable across rebuilds and
# grants persist. With ad-hoc (-), TCC keys on the cdhash, which changes on
# every single build, so Accessibility / Calendar / Bluetooth re-prompt forever.
#
# usage: sign.sh <app-path> <identity>
#
# LEDGE_DIST=1 signs for distribution: secure timestamps from Apple's timestamp
# service (notarization rejects builds without them). Needs network, so the
# development default stays offline-fast with --timestamp=none.
set -euo pipefail

APP="${1:?app path required}"
IDENTITY="${2:--}"

TIMESTAMP="--timestamp=none"
if [[ "${LEDGE_DIST:-0}" == "1" ]]; then
    TIMESTAMP="--timestamp"
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT/Bundle/Ledge.entitlements"

# A predictable path in world-writable /tmp follows symlinks and collides
# between concurrent builds.
ERRLOG="$(mktemp -t ledge-sign)"
trap 'rm -f "$ERRLOG"' EXIT

# Building under ~/Desktop means Finder tags and quarantine attributes end up on
# the bundle, and codesign refuses those with "resource fork, Finder
# information, or similar detritus not allowed".
xattr -cr "$APP"

# Read back from the bundle rather than hardcoded: bundle.sh gives a
# development build its own identifier, and `codesign --identifier` is what TCC
# actually binds a grant to. Signing a debug bundle as the shipped identifier
# would leave the collision in place with the plist merely pretending otherwise.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"


# --deep is deliberately not used: it re-signs nested code with the outer
# entitlements, which is wrong and is a documented footgun.
# Nested code must be signed independently, and BEFORE the outer bundle, or
# `codesign --verify --strict` rejects the app with "code object is not signed
# at all". `--deep` would do this for us and is a documented footgun (it applies
# the outer entitlements to nested code), so it is done by hand instead. The
# adapter is dlopened by /usr/bin/perl rather than loaded by Ledge, so it wants
# neither Ledge's identifier nor Ledge's entitlements. `--options runtime` is
# omitted deliberately: the hardened runtime flag is inert on a dylib, and the
# process that loads it is not hardened.
shopt -s nullglob
for dylib in "$APP"/Contents/Frameworks/*.dylib; do
    codesign --force "$TIMESTAMP" \
        --identifier "$BUNDLE_ID.mediaadapter" \
        --sign "$IDENTITY" "$dylib"
    echo "signed nested $(basename "$dylib")"
done
shopt -u nullglob

# Sparkle's own nested executables must be signed innermost-first, each with
# the hardened runtime — notarization checks every one of them. The list and
# order follow Sparkle's sandboxing documentation. A distribution bundle
# without the framework is a bundle that crashes at launch, so under LEDGE_DIST
# its absence is an error rather than something to sign around.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" && "${LEDGE_DIST:-0}" == "1" ]]; then
    echo "error: $SPARKLE_FW is missing — the release would die at launch with dyld" >&2
    echo "       \"Library not loaded\". Re-run 'make release' so bundle.sh copies it." >&2
    exit 1
fi
if [[ -d "$SPARKLE_FW" ]]; then
    SPARKLE_B="$SPARKLE_FW/Versions/B"
    codesign --force "$TIMESTAMP" --options runtime \
        --sign "$IDENTITY" "$SPARKLE_B/XPCServices/Installer.xpc"
    # Downloader keeps its own entitlements (network client), so preserve them.
    codesign --force "$TIMESTAMP" --options runtime --preserve-metadata=entitlements \
        --sign "$IDENTITY" "$SPARKLE_B/XPCServices/Downloader.xpc"
    codesign --force "$TIMESTAMP" --options runtime \
        --sign "$IDENTITY" "$SPARKLE_B/Autoupdate"
    codesign --force "$TIMESTAMP" --options runtime \
        --sign "$IDENTITY" "$SPARKLE_B/Updater.app"
    codesign --force "$TIMESTAMP" \
        --sign "$IDENTITY" "$SPARKLE_FW"
    echo "signed nested Sparkle.framework"
fi

ARGS=(--force "$TIMESTAMP" --identifier "$BUNDLE_ID")

if [[ "$IDENTITY" != "-" ]]; then
    # Hardened runtime only with a real identity — it interferes with dlopen of
    # private frameworks under ad-hoc signing.
    ARGS+=(--options runtime)
fi

if [[ -f "$ENTITLEMENTS" ]]; then
    ARGS+=(--entitlements "$ENTITLEMENTS")
fi

if ! codesign "${ARGS[@]}" --sign "$IDENTITY" "$APP" 2>"$ERRLOG"; then
    cat "$ERRLOG" >&2
    # An Apple Development certificate can only carry entitlements the machine
    # is provisioned for. Retry bare, but only for that specific failure —
    # anything else is a real error and should stop the build. Never for a
    # distribution build: a release signed without entitlements ships fine and
    # then never shows the Calendar / Location / Bluetooth prompts, which is a
    # bug nobody would trace back to here.
    if grep -qiE "entitlement|provisioning" "$ERRLOG"; then
        if [[ "${LEDGE_DIST:-0}" == "1" ]]; then
            echo "error: entitlements could not be applied to the distribution build." >&2
            echo "       Not retrying without them — the release would silently lose its" >&2
            echo "       Calendar / Location / Bluetooth prompts. Fix the identity or" >&2
            echo "       $ENTITLEMENTS and re-run 'make release'." >&2
            exit 1
        fi
        echo "warning: retrying without entitlements (get-task-allow unavailable)" >&2
        # Keep every flag except --entitlements. Dropping --options runtime
        # here too would silently ship a build without the hardened runtime,
        # differing from the intended output with nothing to signal it.
        RETRY=(--force "$TIMESTAMP" --identifier "$BUNDLE_ID")
        [[ "$IDENTITY" != "-" ]] && RETRY+=(--options runtime)
        codesign "${RETRY[@]}" --sign "$IDENTITY" "$APP"
    else
        exit 1
    fi
fi

codesign --verify --strict --verbose=1 "$APP"

if [[ "$IDENTITY" == "-" ]]; then
    cat >&2 <<'EOF'
warning: signed ad-hoc. Every rebuild will invalidate TCC grants, so
         Accessibility / Calendar / Bluetooth will re-prompt each time.
         Set SIGN_ID to an "Apple Development" identity to avoid this.
EOF
fi

echo "signed $APP with ${IDENTITY}"
