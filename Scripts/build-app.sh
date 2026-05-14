#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/modulecache-VoiceMemoRenamer}"
CONFIGURATION="${CONFIGURATION:-debug}"

swift build -c "$CONFIGURATION"

APP_DIR="$ROOT_DIR/.build/VoiceMemoRenamer.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION/VoiceMemoRenamer"

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    EXECUTABLE_PATH="$ROOT_DIR/.build/$CONFIGURATION/VoiceMemoRenamer"
fi

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    echo "Could not find built executable for configuration: $CONFIGURATION" >&2
    exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/Support/VoiceMemoRenamer-Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/VoiceMemoRenamer"
cp "$ROOT_DIR/Support/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if [[ -f "$ROOT_DIR/Support/AppIconDark.icns" ]]; then
    cp "$ROOT_DIR/Support/AppIconDark.icns" "$RESOURCES_DIR/AppIconDark.icns"
fi

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
