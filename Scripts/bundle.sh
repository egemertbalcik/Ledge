#!/bin/bash
# Assemble a .app bundle from SwiftPM build products.
#
# usage: bundle.sh <config> <app-path> [build-dir]
#
# <build-dir> is where SwiftPM put the products. It defaults to .build/<config>,
# which is what a plain `swift build` fills; the universal release build lands
# in .build/apple/Products/Release instead, and the Makefile passes that. Every
# piece copied below — executable, dylibs, resource bundles — comes from this
# one directory, so a stale arm64-only dylib can never ride along with a
# universal executable.
#
# LEDGE_DIST=1 builds a distribution bundle: development fixtures are left out,
# and the result must be universal (arm64 + x86_64) or the script fails.
set -euo pipefail

CONFIG="${1:-debug}"
APP="${2:-build/Ledge.app}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${3:-$ROOT/.build/$CONFIG}"
# A relative build-dir (as the Makefile passes it) is relative to the project.
[[ "$BUILD_DIR" == /* ]] || BUILD_DIR="$ROOT/$BUILD_DIR"

cd "$ROOT"

if [[ ! -x "$BUILD_DIR/Ledge" ]]; then
    echo "error: $BUILD_DIR/Ledge not found — run 'swift build' first" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Ledge" "$APP/Contents/MacOS/Ledge"
cp "$ROOT/Bundle/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM emits resource bundles next to the executable and Bundle.module looks
# for them in Contents/Resources. Missing this traps at runtime, not build time.
shopt -s nullglob
for resource_bundle in "$BUILD_DIR"/*.bundle; do
    cp -R "$resource_bundle" "$APP/Contents/Resources/"
done

# Any dylibs the build produced (e.g. the media adapter).
mkdir -p "$APP/Contents/Frameworks"
for dylib in "$BUILD_DIR"/*.dylib; do
    cp "$dylib" "$APP/Contents/Frameworks/"
done

# Sparkle is a binary SwiftPM artifact; the executable links it via
# @rpath/../Frameworks, so the framework must ride along. cp -R keeps the
# Versions symlink structure intact, which codesign requires. The xcframework
# slice directory is named after the arches it holds, so it is located rather
# than spelled out. Silently skipping it is not an option: the app would then
# die at first launch with dyld "Library not loaded", long after the build
# reported success.
# (Captured first: `grep -q` can close the pipe before otool is done writing,
# and under pipefail that reads as a failure.)
LINKED="$(otool -L "$APP/Contents/MacOS/Ledge")"
if grep -q "Sparkle.framework" <<<"$LINKED"; then
    SPARKLE="$(find "$ROOT/.build/artifacts" -type d -path "*/Sparkle.xcframework/macos*/Sparkle.framework" -print -quit 2>/dev/null || true)"
    if [[ -z "$SPARKLE" ]]; then
        echo "error: Ledge links Sparkle.framework but no framework was found under .build/artifacts" >&2
        echo "       run 'swift package resolve' (or a full 'swift build') to fetch the Sparkle artifact" >&2
        exit 1
    fi
    cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
fi

rmdir "$APP/Contents/Frameworks" 2>/dev/null || true
shopt -u nullglob

# Sparkle orders updates by CFBundleVersion, so every release needs a strictly
# larger one than the last. The commit count gives that for free and cannot be
# forgotten, so it is stamped onto the COPIED plist here; the source plist keeps
# its placeholder. Outside a git checkout (a tarball) the plist's own value stands.
#
# The floor keeps the count above every build that has ever been released, so
# CFBundleVersion can never go backwards — an update numbered below what is
# already installed is refused silently, and the only remedy would be asking
# every user to download the app again by hand. Never lower it.
BUILD_FLOOR=300
PLIST="$APP/Contents/Info.plist"
COMMIT_COUNT="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
if [[ -n "$COMMIT_COUNT" ]]; then
    BUILD_NUMBER=$(( BUILD_FLOOR + COMMIT_COUNT ))
else
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
    echo "warning: not a git checkout — CFBundleVersion left at $BUILD_NUMBER from Info.plist" >&2
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
echo "CFBundleVersion $BUILD_NUMBER"

# A debug build is a different app, and macOS is told so.
#
# It used to carry the shipped identifier, which meant the two shared
# everything macOS keys to it: the same TCC grants and the same preferences
# domain. A rebuild-and-relaunch during development would take over the
# installed app's Accessibility grant — TCC binds a grant to the signature
# that was in front of it, and the two are signed with different certificates
# — so the installed copy silently lost a permission its switch still claimed
# to have. It also consumed first-run flags, making a genuine first launch
# impossible to test on a machine that had ever built the app. Whole evenings
# went into chasing that.
#
# The name changes with it, so two entries in System Settings' permission
# lists can be told apart.
if [[ "${LEDGE_DIST:-0}" != "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.egemert.ledge.debug" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Ledge (debug)" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Ledge (debug)" "$PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ledge (debug)" "$PLIST"
    # And it must never update itself into the real app.
    for key in SUFeedURL SUEnableAutomaticChecks; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
    done
    echo "CFBundleIdentifier com.egemert.ledge.debug (development build)"
fi

# A distribution bundle must run on both Intel and Apple Silicon. Checked here,
# on the copies, so an arm64-only executable from a plain `swift build` cannot
# be shipped by pointing bundle.sh at the wrong directory.
if [[ "${LEDGE_DIST:-0}" == "1" ]]; then
    shopt -s nullglob
    for binary in "$APP/Contents/MacOS/Ledge" "$APP"/Contents/Frameworks/*.dylib; do
        ARCHS="$(lipo -archs "$binary")"
        if [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
            echo "error: $(basename "$binary") is not universal (archs: $ARCHS)" >&2
            echo "       distribution needs arm64 + x86_64 — build with 'make release'" >&2
            exit 1
        fi
    done
    shopt -u nullglob
fi

# Development fixtures, opt-in at runtime via LEDGE_FAKE_ACTIVITIES=1. They are
# scaffolding, not product, so a distribution bundle ships without them.
if [[ "${LEDGE_DIST:-0}" != "1" && -d "$ROOT/Fixtures/scenarios" ]]; then
    cp -R "$ROOT/Fixtures/scenarios" "$APP/Contents/Resources/scenarios"
fi

if [[ -f "$ROOT/build/AppIcon.icns" ]]; then
    cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Info.plist must parse, or launchd rejects the bundle with a useless error.
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "bundled $APP"
