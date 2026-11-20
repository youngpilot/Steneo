#!/bin/bash
# Release check C: build the capture core from the app's own source files and
# run it against this Mac's microphones. Silent: records the room for about
# ten seconds, plays nothing, changes no volume, switches no device.
# Exit: 0 held · 1 broken · 2 nothing could be judged.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d -t steneo-check-capture)"
trap 'rm -rf "$OUT"' EXIT

# -D DEBUG: the check injects a failing microphone through the same hook the
# unit tests use.
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 5 -O -D DEBUG \
        "$PROJECT_DIR/scripts/check-capture.swift" \
        "$PROJECT_DIR/Steneo/Services/AudioDeviceResolver.swift" \
        "$PROJECT_DIR/Steneo/Services/DeviceInputStream.swift" \
        "$PROJECT_DIR/Steneo/Services/AudioCaptureService.swift" \
        "$PROJECT_DIR/Steneo/Services/AudioResampler.swift" \
        -o "$OUT/check-capture" 2> "$OUT/build.log"; then
    grep -E "error:" "$OUT/build.log" | head -10
    echo "Check C could not be built. That is a fault in the check or in the capture sources."
    exit 1
fi
"$OUT/check-capture"
