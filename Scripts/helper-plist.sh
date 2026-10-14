#!/bin/bash
# Write the privileged helper's launchd plist, with the code-signing
# requirement derived from the identity that is about to sign this build.
#
# usage: helper-plist.sh <app-path> <identity>
#
# Why this is its own script, run from sign.sh rather than bundle.sh: the
# requirement is a fact about the signature, and only sign.sh knows which
# identity is being used. The plist has to be inside the bundle before the app
# is sealed, so it cannot be written afterwards either. This is the one moment
# where both things are true.
#
# Why the requirement is never written down in a source file: the daemon runs
# as root and the requirement is the whole of its answer to "who is allowed to
# tell me what to do". A literal in the repository is a literal that goes stale
# silently — it keeps compiling, it keeps installing, and the only symptom is a
# feature that stops working on one of the two build paths. Derived here, each
# build trusts exactly the identity that signed it and nothing else.
#
# Both of this project's identities happen to carry the same subject OU
# (the team), so a hardcoded one would in fact match today. It is still derived:
# the OU is not the only difference between them — a Developer ID signature also
# carries two certificate extensions that an Apple Development signature does
# not, and the requirement must demand them on a release build and must not on a
# development one.
set -euo pipefail

APP="${1:?app path required}"
IDENTITY="${2:?signing identity required}"

PLIST_IN="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST_IN")"
LABEL="$BUNDLE_ID.keepawake"
HELPER="$APP/Contents/MacOS/LedgeKeepAwakeHelper"
DAEMONS="$APP/Contents/Library/LaunchDaemons"
PLIST_OUT="$DAEMONS/$LABEL.plist"

if [[ ! -x "$HELPER" ]]; then
    echo "helper not in the bundle; lid-closed mode is not part of this build" >&2
    exit 0
fi

# Ad-hoc cannot be the basis of a requirement.
#
# `anchor apple generic` asks for a certificate chain rooting at Apple, and an
# ad-hoc signature has no chain at all, so no requirement written here could
# ever match. Rather than ship a daemon nothing can talk to, the helper is
# dropped from the bundle and the app reports the feature as unavailable on an
# unsigned build. Failing here instead would block every development build of
# every other feature.
if [[ "$IDENTITY" == "-" ]]; then
    rm -f "$HELPER"
    rm -rf "$DAEMONS"
    /usr/libexec/PlistBuddy -c "Delete :LedgeHelperRequirement" "$PLIST_IN" 2>/dev/null || true
    echo "ad-hoc signed: helper left out, lid-closed mode unavailable in this build" >&2
    exit 0
fi

# The identity is a SHA-1 hash (that is what the Makefile selects), so the
# certificate is found by hash rather than by name — two identities whose names
# share a prefix would otherwise be indistinguishable.
CERT="$(mktemp -t ledge-helper-cert)"
trap 'rm -f "$CERT"' EXIT
security find-certificate -a -Z -p > "$CERT"

# Each entry is a "SHA-1 hash: ..." line followed by its PEM block.
PEM="$(awk -v want="$IDENTITY" '
    /^SHA-1 hash:/ { match($0, /[0-9A-F]{40}/); here = substr($0, RSTART, RLENGTH) }
    /BEGIN CERTIFICATE/ { collecting = (here == want); block = "" }
    collecting { block = block $0 "\n" }
    /END CERTIFICATE/ { if (collecting) { printf "%s", block; exit } }
' "$CERT")"

if [[ -z "$PEM" ]]; then
    echo "error: no certificate in the keychain with hash $IDENTITY" >&2
    exit 1
fi

SUBJECT="$(printf '%s' "$PEM" | openssl x509 -noout -subject)"
TEAM="$(printf '%s' "$SUBJECT" | tr ',' '\n' | sed -n 's/.*OU[ ]*=[ ]*//p' | head -1 | xargs)"
COMMON="$(printf '%s' "$SUBJECT" | tr ',' '\n' | sed -n 's/.*CN[ ]*=[ ]*//p' | head -1)"

if [[ -z "$TEAM" ]]; then
    echo "error: certificate $IDENTITY has no subject OU to build a requirement from" >&2
    exit 1
fi

# A Developer ID signature carries two extensions an Apple Development one does
# not: the Developer ID intermediate's marker and the Developer ID Application
# leaf's. Demanding them on a release build is what stops a development
# certificate — ours or anyone's with the same team — from satisfying the
# shipped daemon. Demanding them on a development build would mean the daemon
# could never accept the app it ships beside. (TN3127.)
if [[ "$COMMON" == "Developer ID Application:"* ]]; then
    PEDIGREE=' and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]'
    KIND="Developer ID"
else
    PEDIGREE=''
    KIND="development"
fi

# What the daemon demands of whoever connects to it: the app, and only the app.
CLIENT_REQ="anchor apple generic and identifier \"$BUNDLE_ID\"$PEDIGREE and certificate leaf[subject.OU] = \"$TEAM\""
# What the app demands of the daemon, in the same shape. Each side checks the
# other; a daemon that only checked its clients could still be impersonated.
HELPER_REQ="anchor apple generic and identifier \"$LABEL\"$PEDIGREE and certificate leaf[subject.OU] = \"$TEAM\""

# Compile both before they are written anywhere. The daemon treats a malformed
# requirement as a fatal error, which from launchd's point of view is a job
# that dies on a ten-second throttle forever; catching it here makes it a build
# failure instead.
for requirement in "$CLIENT_REQ" "$HELPER_REQ"; do
    if ! printf '%s' "$requirement" | csreq -r - -b /dev/null 2>/dev/null; then
        echo "error: the requirement does not compile:" >&2
        echo "       $requirement" >&2
        exit 1
    fi
done

mkdir -p "$DAEMONS"
cat > "$PLIST_OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/LedgeKeepAwakeHelper</string>
    <key>ProgramArguments</key>
    <array>
        <string>Contents/MacOS/LedgeKeepAwakeHelper</string>
        <string>--client</string>
        <string>$BUNDLE_ID</string>
        <string>--requirement</string>
        <string>$(printf '%s' "$CLIENT_REQ" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>$LABEL</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$BUNDLE_ID</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

# The requirement contains double quotes, so confirm it survived the plist
# rather than trusting that it did.
plutil -lint "$PLIST_OUT" > /dev/null
ROUND_TRIPPED="$(plutil -extract ProgramArguments.4 raw -o - "$PLIST_OUT")"
if [[ "$ROUND_TRIPPED" != "$CLIENT_REQ" ]]; then
    echo "error: the requirement did not survive being written to the plist" >&2
    echo "       wrote: $CLIENT_REQ" >&2
    echo "       read:  $ROUND_TRIPPED" >&2
    exit 1
fi

# The app needs the other half at runtime, to check the daemon it is talking to.
#
# `plutil -replace`, not PlistBuddy: PlistBuddy takes its whole instruction as
# one string and parses it again itself, which silently eats the double quotes
# around the identifier and the team. The requirement still looks right in the
# file to a reader skimming it, still has every word in the right order, and
# fails to compile the moment anything tries to use it. plutil takes the value
# as its own argument and does not reinterpret it.
plutil -replace LedgeHelperRequirement -string "$HELPER_REQ" "$PLIST_IN"

# Both halves are checked, not just the one that looked riskier. The half that
# broke first was the half with no round-trip check on it.
APP_SIDE="$(/usr/libexec/PlistBuddy -c 'Print LedgeHelperRequirement' "$PLIST_IN")"
if [[ "$APP_SIDE" != "$HELPER_REQ" ]]; then
    echo "error: the helper requirement did not survive being written to Info.plist" >&2
    echo "       wrote: $HELPER_REQ" >&2
    echo "       read:  $APP_SIDE" >&2
    exit 1
fi

echo "helper plist written for $LABEL ($KIND identity)"
