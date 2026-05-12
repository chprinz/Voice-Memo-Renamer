#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/modulecache}"

swift build

APP_DIR="$ROOT_DIR/.build/VoiceMemoRenamer.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/Support/VoiceMemoRenamer-Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/.build/arm64-apple-macosx/debug/VoiceMemoRenamer" "$MACOS_DIR/VoiceMemoRenamer"
cp "$ROOT_DIR/Support/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if [[ -f "$ROOT_DIR/Support/AppIconDark.icns" ]]; then
    cp "$ROOT_DIR/Support/AppIconDark.icns" "$RESOURCES_DIR/AppIconDark.icns"
fi

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
