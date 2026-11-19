#!/bin/bash
# Release check B: you dictate one sentence, Steneo's own log says whether the
# whole chain ran — shortcut, microphone, speech model, insertion.
#
# This replaces 630 lines that existed to stand in for a person saying one
# sentence: switching the output to speakers, raising the volume, measuring the
# room, proving the microphone can hear the Mac, bringing TextEdit to the front.
# Those parts raised nine false alarms in two sessions (headphones, a noisy
# room, a lost permission, a time zone) while the app was fine every time.
# A release is started by a person anyway; five seconds of their voice test the
# real microphone, the real voice and the real target app, which the machine
# version never did.
#
#   check-dictation.sh                 wait for a dictation (up to 120 s)
#   check-dictation.sh --since "2026-11-19 18:25:00" --wait 0
#                                      judge a past window, for checking this script
#
# Exit 0 = a dictation ran through. 1 = it ran and broke. 2 = nothing to judge.
set -uo pipefail

WAIT=120
SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        --wait)  WAIT="$2";  shift 2 ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
done

if ! pgrep -x Steneo >/dev/null; then
    echo "ABORT: Steneo is not running. Nothing was measured."
    exit 2
fi

ASK=0
if [ -z "$SINCE" ]; then
    SINCE="$(date '+%Y-%m-%d %H:%M:%S')"   # local time: `log show --start` reads it as local
    ASK=1
fi

# /usr/bin/log, never bare `log`: in zsh that is a builtin and returns nothing.
steneo_log() {
    /usr/bin/log show --start "$SINCE" --info --style compact \
        --predicate 'subsystem == "com.youngpilot.Steneo"' 2>/dev/null
}

if [ "$ASK" -eq 1 ]; then
    echo "· dictate ONE sentence now, anywhere (waiting up to ${WAIT} s)"
    osascript -e 'display notification "Dictate one sentence now, anywhere." with title "Steneo release check" sound name "Glass"' >/dev/null 2>&1 || true
fi

DEADLINE=$(( $(date +%s) + WAIT ))
while :; do
    LOG="$(steneo_log)"
    STARTED="$(printf '%s\n' "$LOG" | grep -E 'Start [0-9]+ ms on ' | tail -1 | sed 's/^.*AudioCapture\] //')"
    TRANSCRIPT="$(printf '%s\n' "$LOG" | grep -E 'final transcript \([1-9][0-9]* chars\)' | tail -1)"
    INSERTED="$(printf '%s\n' "$LOG" | grep -F 'insertText:' | tail -1)"
    TIMING="$(printf '%s\n' "$LOG" | grep -E 'Transcribed [0-9.]+ s of audio in ' | tail -1 | sed 's/^.*Transcription\] //')"
    FAILED="$(printf '%s\n' "$LOG" | grep -E 'Capture failed|No microphone could be started|Transcription failed' | tail -1 | sed 's/^.*Steneo:[A-Za-z]*\] //')"

    if [ -n "$STARTED" ] && [ -n "$TRANSCRIPT" ] && [ -n "$INSERTED" ]; then
        echo "  microphone : $STARTED"
        echo "  model      : ${TIMING:-transcribed}"
        echo "  inserted   : yes"
        echo "RESULT: PASS — shortcut, microphone, model and insertion all ran."
        exit 0
    fi
    if [ -n "$FAILED" ]; then
        echo "  $FAILED"
        echo "RESULT: FAILED — a dictation was started and broke (see the line above)."
        exit 1
    fi
    [ "$(date +%s)" -ge "$DEADLINE" ] && break
    sleep 2
done

if [ -n "$STARTED" ]; then
    echo "  microphone : $STARTED"
    echo "ABORT: a recording started, but no text came out of it — was a sentence spoken?"
    echo "       Nothing was judged; this says nothing about the build."
else
    echo "ABORT: nobody dictated within ${WAIT} s. Nothing was measured."
fi
exit 2
