#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
APP_NAME="VoiceMemoRenamer"
DISPLAY_NAME="Voice Memo Renamer"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$ROOT_DIR/.build/dmg-staging"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

APP_DIR="$(CONFIGURATION=release "$ROOT_DIR/Scripts/build-app.sh" | tail -n 1)"

cp -R "$APP_DIR" "$STAGING_DIR/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$DISPLAY_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "$DMG_PATH"
