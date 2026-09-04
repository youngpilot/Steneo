#!/bin/bash
set -euo pipefail

VERSION="1.4.3"
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

# --- Both gates take over this Mac. Say so, and ask. ------------------------
# On 04.09.2026 check B ran four times unannounced while the user was working:
# it changed the volume, spoke out loud and quit his running Steneo. Worse, he
# was wearing headphones, so it measured nothing and reported the app as broken.
cat <<'NOTE'
The two release gates take over this Mac for a few minutes:
  A · opens TextEdit and types into it (silent)
  B · sets the volume to 45, speaks two sentences OUT LOUD, quits the running
      Steneo and runs the build under test instead
Everything is put back afterwards.

Check B needs SPEAKERS. With headphones the microphone cannot hear the Mac and
the check has nothing to measure — it will refuse rather than guess.
NOTE
read -r -p "Run the gates now? [y/N] " answer
case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted before anything was touched."; exit 1 ;;
esac
export STENEO_GATE_CONFIRM=1
echo ""

# --- Gate A: does text survive insertion character for character? ------------
# Notarisation and Gatekeeper say nothing about whether the product works. This
# release shipped a character-dropping insertion path three times because the
# pipeline only ever checked signatures. It stops here now.
echo "=== Gate A: insertion fidelity (opens TextEdit briefly) ==="
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
    "$PROJECT_DIR/scripts/check-insertion.swift" -o /tmp/steneo-check-insertion
A_STATUS=0
/tmp/steneo-check-insertion || A_STATUS=$?
if [ "$A_STATUS" -eq 2 ] || [ "$A_STATUS" -eq 3 ]; then
    echo "ABORT: check A could not measure anything (see above). This says NOTHING"
    echo "       about the build. Fix the setup and run the release again."
    exit 1
fi
if [ "$A_STATUS" -ne 0 ]; then
    echo "ABORT: insertion is not character-exact. Nothing was released."
    exit 1
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
echo "=== Gate B: press, speak, text arrives (speaks out loud, ~1 min) ==="
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
    "$PROJECT_DIR/scripts/check-core-chain.swift" -o /tmp/steneo-check-core-chain
B_STATUS=0
/tmp/steneo-check-core-chain "$APP_PATH" || B_STATUS=$?
if [ "$B_STATUS" -eq 2 ] || [ "$B_STATUS" -eq 3 ]; then
    # 2 = could not measure (headphones, no mic, muted), 3 = not confirmed.
    # Neither is a statement about the app, so neither may read as one.
    echo "ABORT: check B could not measure anything (see above). This says NOTHING"
    echo "       about the build. Fix the setup and run the release again."
    exit 1
fi
if [ "$B_STATUS" -ne 0 ]; then
    echo "ABORT: the core chain failed on the build being released. Nothing was released."
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
echo "=== Gatekeeper assessment ==="
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" || true
spctl -a -t exec -vv "$APP_PATH" || true

echo ""
echo "Done: $DMG_PATH"
