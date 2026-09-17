#!/bin/bash
# Enforce the target boundaries the architecture depends on.
#
# LedgeCore must stay pure: the moment it imports AppKit or SwiftUI, the headless
# test story is gone and the reducer stops being testable without a WindowServer.
# LedgeUI must not reach for AppKit or system frameworks — it takes values.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0

check() {
    local target="$1"
    local pattern="$2"
    local dir="$ROOT/Sources/$target"
    [[ -d "$dir" ]] || return 0

    local hits
    hits=$(grep -rnE "^[[:space:]]*(@[a-zA-Z]+ )?import ($pattern)\b" "$dir" || true)
    if [[ -n "$hits" ]]; then
        echo "error: $target must not import: $pattern" >&2
        echo "$hits" >&2
        STATUS=1
    fi
}

check LedgeCore   'AppKit|SwiftUI|IOKit|CoreAudio|CoreMediaIO|CoreBluetooth|Network|EventKit|IOBluetooth|CoreLocation|LedgeAudioListen|LedgeSystem|LedgeShell|LedgeUI'
check LedgeUI     'AppKit|IOKit|CoreAudio|CoreMediaIO|CoreBluetooth|Network|EventKit|IOBluetooth|LedgeAudioListen|LedgeSystem|LedgeShell'
check LedgeSystem 'SwiftUI|LedgeShell|LedgeUI'

# CoreAudio and CoreMediaIO match a listener for removal by the block pointer it
# was registered with, and Swift cannot hand them the same pointer twice: the
# listener typedefs import as thick closures, so every crossing mints a new
# block. Removal then matches nothing, leaves the listener installed, and still
# returns noErr. That went unnoticed until a shipped build reached 1.5 million
# live registrations and spent the whole main thread scanning them.
#
# So these calls belong only in LedgeAudioListen, which owns the block in C.
# Swift reaches them through AudioListener.
audio_hits=$(grep -rnE '(AudioObject|CMIOObject)(Add|Remove)PropertyListenerBlock' \
    "$ROOT/Sources" --include='*.swift' || true)
if [[ -n "$audio_hits" ]]; then
    echo "error: register audio listeners through AudioListener, not directly —" >&2
    echo "       Swift cannot pass the same block pointer twice, so removal silently fails" >&2
    echo "$audio_hits" >&2
    STATUS=1
fi

if [[ $STATUS -eq 0 ]]; then
    echo "import boundaries ok"
fi
exit $STATUS
