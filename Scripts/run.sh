#!/bin/bash
# Kill any running copy and launch the freshly-built one.
#
# The binary is executed from *inside* the bundle rather than via `open`. It
# still gets full bundle identity (Bundle.main, code signature, TCC identity),
# but stdout/stderr stream to this terminal. With no Xcode console attached,
# that detail is worth more than any other dev-loop trick.
#
# usage: run.sh <app-path>
set -uo pipefail

APP="${1:?app path required}"

pkill -x Ledge 2>/dev/null || true

# pkill returns before the process is actually gone; the single-instance guard
# would otherwise see the old copy and exit immediately.
for _ in $(seq 1 20); do
    pgrep -x Ledge > /dev/null || break
    sleep 0.05
done

LEDGE_DEBUG="${LEDGE_DEBUG:-1}" exec "$APP/Contents/MacOS/Ledge"
