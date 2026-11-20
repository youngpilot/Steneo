#!/bin/bash
# Release check B: the installed bundle checks itself. No person needed.
#
# Writes one sentence to a file with `say -o` (nothing is played), relaunches the
# installed Steneo with `--release-self-check <file>`, and reads the app's own
# log: did the microphone deliver sound, and did the speech model turn the file
# into the sentence? Plays nothing, changes no volume, switches no device,
# types nothing.
#
# Exit: 0 passed · 1 broken · 2 nothing could be judged.
set -uo pipefail

APP="${1:-/Applications/Steneo.app}"
SENTENCE="Please send the weekly report to the whole team before noon tomorrow."
WAIT=90

WORK="$(mktemp -d -t steneo-check-installed)"
trap 'rm -rf "$WORK"' EXIT
AUDIO="$WORK/sentence.aiff"
if ! say -v Samantha -o "$AUDIO" "$SENTENCE" 2>/dev/null && ! say -o "$AUDIO" "$SENTENCE"; then
    echo "ABORT: could not write the test sentence. Nothing was measured."
    exit 2
fi

osascript -e 'tell application "Steneo" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -x Steneo 2>/dev/null || true
sleep 1
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"   # local time: `log show --start` reads it as local
open -a "$APP" --args --release-self-check "$AUDIO"

# /usr/bin/log, never bare `log`: in zsh that is a builtin and returns nothing.
selfcheck_log() {
    /usr/bin/log show --start "$SINCE" --info --style compact \
        --predicate 'subsystem == "com.youngpilot.Steneo" AND category == "SelfCheck"' 2>/dev/null
}

DEADLINE=$(( $(date +%s) + WAIT ))
until selfcheck_log | grep -q "Self-check finished"; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        if selfcheck_log | grep -q "Self-check started"; then
            echo "ABORT: the self-check started but did not finish within ${WAIT} s."
            exit 1
        fi
        echo "ABORT: the app never started its self-check. Nothing was measured."
        exit 2
    fi
    sleep 1
done

LOG="$(selfcheck_log)"
MIC="$(printf '%s\n' "$LOG" | grep -E "Self-check microphone" | tail -1 | sed 's/^.*Self-check //')"
MODEL="$(printf '%s\n' "$LOG" | grep -E "Self-check model" | tail -1 | sed 's/^.*Self-check //')"
echo "  $MIC"
echo "  $MODEL"

STATUS=0
case "$MIC" in "microphone OK"*) ;; *) STATUS=1 ;; esac
case "$MODEL" in
    "model OK"*)
        # Share of the sentence's words that came back. The model is not
        # perfect on a synthetic voice; a broken pipeline gets near zero.
        HEARD="${MODEL#*: }"
        SHARE="$(python3 - "$SENTENCE" "$HEARD" <<'EOF'
import re, sys
words = lambda s: re.findall(r"[a-z']+", s.lower())
expected, heard = words(sys.argv[1]), set(words(sys.argv[2]))
print(round(100 * sum(w in heard for w in expected) / len(expected)))
EOF
)"
        echo "  $SHARE % of the sentence recognised"
        [ "$SHARE" -ge 70 ] || STATUS=1
        ;;
    *) STATUS=1 ;;
esac

if [ "$STATUS" -eq 0 ]; then
    echo "RESULT: PASS — microphone and speech model work in the installed bundle."
else
    echo "RESULT: FAIL — see the lines above."
fi
exit "$STATUS"
