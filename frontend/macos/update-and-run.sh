#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/drWisper.app"
INSTALL_PATH="$HOME/Applications/drWisper.app"
LOG_PATH="$HOME/Library/Logs/drWisper/drwisper.log"

pkill -f 'Contents/MacOS/(DrWisperMac|drWisper)' 2>/dev/null || true
"$SCRIPT_DIR/build-app.sh" >/dev/null
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_PATH"
ditto "$APP_PATH" "$INSTALL_PATH"
open "$INSTALL_PATH"

BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_PATH/Contents/Info.plist")"

echo "drWisper is running."
echo "Build: $BUILD_VERSION"
echo "App: $INSTALL_PATH"
echo "Log: $LOG_PATH"
