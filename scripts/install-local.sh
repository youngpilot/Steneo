#!/bin/bash
# Build the current checkout exactly as a release is built (Release, Developer ID,
# hardened runtime) and put it in /Applications — without notarising or publishing.
# For trying a version in daily use before it is released. The signature is the
# same identity as the released app, so microphone and accessibility access stay.
# The app that was installed before is kept in build/local/previously-installed.app;
# `scripts/install-local.sh --restore` puts it back.
set -euo pipefail

NAME="Steneo"
TEAM_ID="${STENEO_TEAM_ID:-5A4T37N77V}"
IDENTITY="Developer ID Application: ${STENEO_SIGNER_NAME:-Julian Schiemann} ($TEAM_ID)"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/local"
DD="$BUILD_DIR/dd"
INSTALLED="/Applications/$NAME.app"
BACKUP="$BUILD_DIR/previously-installed.app"

swap_in() {   # $1 = bundle to install
    osascript -e "tell application \"$NAME\" to quit" >/dev/null 2>&1 || true
    sleep 2
    pkill -x "$NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALLED"
    cp -R "$1" "$INSTALLED"
    open -a "$INSTALLED"
}

version_of() {
    echo "$(defaults read "$1/Contents/Info" CFBundleShortVersionString) ($(defaults read "$1/Contents/Info" CFBundleVersion))"
}

if [ "${1:-}" = "--restore" ]; then
    [ -d "$BACKUP" ] || { echo "Nothing to restore: $BACKUP does not exist."; exit 1; }
    swap_in "$BACKUP"
    echo "Restored $(version_of "$INSTALLED")."
    exit 0
fi

mkdir -p "$BUILD_DIR"
LOG="$BUILD_DIR/build.log"
# Say exactly which state this is. A build made while files are being edited
# is in no commit, and nobody can tell afterwards what is running.
STATE="commit $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain -- Steneo Steneo.xcodeproj)" ]; then
    STATE="$STATE PLUS UNCOMMITTED CHANGES (a state that is in no commit)"
fi
echo "=== Building $NAME (Release, signed, not notarised) from $STATE ==="
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
        -project "$PROJECT_DIR/Steneo.xcodeproj" -scheme "$NAME" -configuration Release \
        -derivedDataPath "$DD" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20
    echo "ABORT: the build failed. Nothing was installed. Full log: $LOG"
    exit 1
fi
BUILT="$DD/Build/Products/Release/$NAME.app"
codesign --verify --deep --strict "$BUILT"

if [ "${1:-}" = "--build-only" ]; then
    echo "Built $(version_of "$BUILT") at $BUILT. Nothing was installed."
    exit 0
fi

# Keep what is installed now, but never overwrite the backup with a local build
# of the same version: the backup is the way back to the released app.
if [ -d "$INSTALLED" ] && [ "$(version_of "$INSTALLED")" != "$(version_of "$BUILT")" ]; then
    rm -rf "$BACKUP"
    cp -R "$INSTALLED" "$BACKUP"
    echo "Kept $(version_of "$BACKUP") in $BACKUP"
fi
swap_in "$BUILT"
echo "Installed $(version_of "$INSTALLED") from $STATE. Back to the previous one: scripts/install-local.sh --restore"
