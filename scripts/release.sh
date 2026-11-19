#!/bin/bash
set -euo pipefail

VERSION="1.7"
DIST_NAME="Steneo"     # user-facing app + DMG name
BUILD_NAME="Steneo"   # internal Xcode product/scheme name (unchanged on purpose)
TEAM_ID="${STENEO_TEAM_ID:?Set STENEO_TEAM_ID env var (Apple Developer Team ID)}"
BUNDLE_ID="com.youngpilot.Steneo"   # unchanged: keeps TCC perms + Keychain history key
IDENTITY="Developer ID Application: ${STENEO_SIGNER_NAME:?Set STENEO_SIGNER_NAME env var (e.g. 'Your Name')} ($TEAM_ID)"
NOTARY_PROFILE="${STENEO_NOTARY_PROFILE:-notary}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
DD="$BUILD_DIR/dd"
BUILT_APP="$DD/Build/Products/Release/$BUILD_NAME.app"   # what xcodebuild produces (Steneo.app)
APP_PATH="$BUILD_DIR/$DIST_NAME.app"                     # renamed distributable (Steneo.app)
DMG_PATH="$BUILD_DIR/$DIST_NAME-$VERSION.dmg"
ZIP_PATH="$BUILD_DIR/$DIST_NAME-$VERSION.zip"

# --- What this run needs from you ----------------------------------------------
# One spoken sentence, once the build is installed (a notification asks for it).
# Nothing here plays sound, changes the volume or switches audio devices. TextEdit
# comes to the front only when the insertion code changed since the last release.
echo "This release will ask you to dictate ONE sentence after the build (a notification tells you when)."
echo ""

# --- Unit tests: silent, about 15 seconds, part of every release -------------
echo "=== Unit tests ==="
TEST_LOG="$(mktemp -t steneo-tests)"
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
        -project "$PROJECT_DIR/Steneo.xcodeproj" -scheme "$BUILD_NAME" \
        -configuration Debug test > "$TEST_LOG" 2>&1; then
    grep -E "error:|failed" "$TEST_LOG" | head -20
    echo "ABORT: unit tests failed. Nothing was released. Full log: $TEST_LOG"
    exit 1
fi
grep -E "Executed [0-9]+ tests, with" "$TEST_LOG" | tail -1
echo ""

# --- Check A: character-exact insertion — ONLY when insertion changed --------
# The check drives a copy of OutputService's two mechanisms into TextEdit. It
# says something new only when that code (or the check itself) changed since
# the last release; otherwise it takes the keyboard for half a minute to
# re-prove what the previous release already proved.
LAST_TAG="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
INSERTION_FILES="Steneo/Services/OutputService.swift scripts/check-insertion.swift"
if [ -n "$LAST_TAG" ] && git -C "$PROJECT_DIR" diff --quiet "$LAST_TAG"..HEAD -- $INSERTION_FILES \
        && git -C "$PROJECT_DIR" diff --quiet -- $INSERTION_FILES; then
    echo "=== Check A skipped: insertion code unchanged since $LAST_TAG ==="
else
    echo "=== Check A: insertion fidelity (TextEdit comes to the front for ~30 s) ==="
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
        "$PROJECT_DIR/scripts/check-insertion.swift" -o /tmp/steneo-check-insertion
    A_STATUS=0
    STENEO_GATE_CONFIRM=1 /tmp/steneo-check-insertion || A_STATUS=$?
    if [ "$A_STATUS" -eq 2 ] || [ "$A_STATUS" -eq 3 ]; then
        echo "ABORT: check A could not measure anything (see above). This says NOTHING"
        echo "       about the build. Fix the setup and run the release again."
        exit 1
    fi
    if [ "$A_STATUS" -ne 0 ]; then
        echo "ABORT: insertion is not character-exact. Nothing was released."
        exit 1
    fi
fi
echo ""

echo "=== Building $DIST_NAME v$VERSION (internal product: $BUILD_NAME) ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build into a dedicated derivedDataPath (NOT SYMROOT — SYMROOT splits the SPM
# product dir and breaks resolution of swift-nio's transitive deps).
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project "$PROJECT_DIR/Steneo.xcodeproj" \
    -scheme "$BUILD_NAME" \
    -configuration Release \
    -derivedDataPath "$DD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    clean build

# Rename the built bundle to the user-facing name. The code signature seals the
# bundle *contents*, not its directory name, so this stays valid (the display
# name comes from CFBundleDisplayName=Steneo; the executable stays Steneo).
echo ""
echo "=== Packaging as $DIST_NAME.app ==="
rm -rf "$APP_PATH"
cp -R "$BUILT_APP" "$APP_PATH"

echo ""
echo "=== Verifying app signature ==="
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -E "Authority|Identifier|Runtime"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo ""
echo "=== Check B: dictate one sentence ==="
# macOS grants microphone access per bundle PATH, so the build is checked where
# the app is installed: install the exact bundle being released, keep the
# previous one to fall back to. The bits under test are the bits that ship.
INSTALLED="/Applications/$DIST_NAME.app"
BACKUP="$BUILD_DIR/previously-installed.app"
if [ -d "$INSTALLED" ]; then
    rm -rf "$BACKUP"
    cp -R "$INSTALLED" "$BACKUP"
fi
osascript -e "tell application \"$DIST_NAME\" to quit" >/dev/null 2>&1 || true
sleep 2
pkill -x "$BUILD_NAME" 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
cp -R "$APP_PATH" "$INSTALLED"
open -a "$INSTALLED"
sleep 4

restore_previous_install() {
    if [ -d "$BACKUP" ]; then
        osascript -e "tell application \"$DIST_NAME\" to quit" >/dev/null 2>&1 || true
        sleep 2
        pkill -x "$BUILD_NAME" 2>/dev/null || true
        sleep 1
        rm -rf "$INSTALLED"
        cp -R "$BACKUP" "$INSTALLED"
        open -a "$INSTALLED"
        echo "· previous install put back"
    fi
}

B_STATUS=0
"$PROJECT_DIR/scripts/check-dictation.sh" || B_STATUS=$?
if [ "$B_STATUS" -eq 2 ]; then
    restore_previous_install
    echo "ABORT: check B had nothing to judge (see above). This says NOTHING about"
    echo "       the build. Run the release again and dictate a sentence when asked."
    exit 1
fi
if [ "$B_STATUS" -ne 0 ]; then
    restore_previous_install
    echo "ABORT: the dictation broke on the build being released. Nothing was released."
    exit 1
fi

echo ""
echo "=== Notarizing app ==="
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

echo ""
echo "=== Building + notarizing DMG ==="
hdiutil create -volname "$DIST_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

echo ""
echo "=== Installing the stapled bundle ==="
# The copy that was gated is unstapled; replace it with the notarised one so the
# machine ends up running exactly what users download.
osascript -e "tell application \"$DIST_NAME\" to quit" >/dev/null 2>&1 || true
sleep 2
pkill -x "$BUILD_NAME" 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
cp -R "$APP_PATH" "$INSTALLED"
open -a "$INSTALLED"

echo ""
echo "=== Gatekeeper assessment ==="
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" || true
spctl -a -t exec -vv "$APP_PATH" || true

echo ""
echo "Done: $DMG_PATH"
