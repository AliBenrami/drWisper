#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/build/drWisper.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE_NAME="drWisper"

cd "$SCRIPT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp ".build/release/DrWisperMac" "$MACOS_DIR/$EXECUTABLE_NAME"

BUILD_VERSION="$(git -C "$SCRIPT_DIR/../.." rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>drWisper</string>
  <key>CFBundleIdentifier</key>
  <string>dev.drwisper.mac</string>
  <key>CFBundleName</key>
  <string>drWisper</string>
  <key>CFBundleDisplayName</key>
  <string>drWisper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>__BUILD_VERSION__</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>drWisper records audio while the activation key is held so it can send speech to your transcription backend.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

/usr/bin/sed -i '' "s/__BUILD_VERSION__/$BUILD_VERSION/g" "$CONTENTS_DIR/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
