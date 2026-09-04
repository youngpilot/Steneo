#!/bin/bash
# The invariant a hung test bought on 04.09.2026.
#
# `AVAudioEngine.inputNode` dispatches SYNCHRONOUSLY to the main queue on first
# access. Anything on `engineQueue` may therefore need main to make progress —
# so nothing may ever block the main thread waiting for `engineQueue`. One
# `engineQueue.sync` from the main actor and the app hangs for good.
#
# This cannot be a unit test: a regression would hang the suite instead of
# failing it. So it is a source check, and it runs before the build.
set -uo pipefail
FILE="$(cd "$(dirname "$0")/.." && pwd)/Steneo/Services/AudioCaptureService.swift"

# Real calls only — the file explains the rule in prose, and prose is not a call.
HITS=$(grep -nE '^[^/]*engineQueue\.sync' "$FILE" || true)

if [ -n "$HITS" ]; then
    echo "FAILED: engineQueue.sync found — the main thread must never wait on the audio queue."
    echo "$HITS"
    echo "Guard the data with its own lock instead (see bufferLock / heartbeatLock)."
    exit 1
fi
echo "ok    no engineQueue.sync — the main thread never waits on the audio queue"
