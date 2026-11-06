#!/bin/zsh

# Builds Claude Pet, installs it to ~/Applications and starts it.
# Running it again replaces the installed copy; the widget keeps its position.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="ClaudePet"
TARGET_DIR="$HOME/Applications"
TARGET="$TARGET_DIR/$APP_NAME.app"

cd "$PROJECT_DIR"
swift build --configuration release
BIN_DIR="$(swift build --configuration release --show-bin-path)"

BUNDLE="$PROJECT_DIR/.build/$APP_NAME.app"
rm -rf -- "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

# App icon: Clawd, drawn by the app itself, in every size macOS asks for.
ICON_SOURCE="$PROJECT_DIR/.build/icon-1024.png"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf -- "$ICONSET"
mkdir -p "$ICONSET" "$BUNDLE/Contents/Resources"
"$BIN_DIR/$APP_NAME" --icon "$ICON_SOURCE"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

# Ad-hoc signatures are pinned to the build's hash, so macOS would ask for calendar, Downloads and
# Spotify access again after every reinstall. A fixed requirement on the bundle id keeps the grants.
codesign --force --sign - --requirements '=designated => identifier "io.github.maiki09k.claudepet"' "$BUNDLE"

pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$TARGET_DIR"
rm -rf -- "$TARGET"
cp -R "$BUNDLE" "$TARGET"
open "$TARGET"

echo "$TARGET"
