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

check LedgeCore   'AppKit|SwiftUI|IOKit|CoreAudio|CoreMediaIO|CoreBluetooth|Network|EventKit|IOBluetooth|CoreLocation|LedgeSystem|LedgeShell|LedgeUI'
check LedgeUI     'AppKit|IOKit|CoreAudio|CoreMediaIO|CoreBluetooth|Network|EventKit|IOBluetooth|LedgeSystem|LedgeShell'
check LedgeSystem 'SwiftUI|LedgeShell|LedgeUI'

if [[ $STATUS -eq 0 ]]; then
    echo "import boundaries ok"
fi
exit $STATUS
