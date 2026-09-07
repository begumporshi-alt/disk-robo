#!/bin/bash
# Builds Disk Robo and wraps the binary in a proper macOS .app bundle.
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/DiskRobo"
SCANNER_BIN=".build/$CONFIG/DiskRoboScanner"
APP="build/DiskRobo.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskRobo"
cp "Scripts/Info.plist" "$APP/Contents/Info.plist"

# Tier 4: the child-process scanner — scans run in it so their memory
# returns to the OS when the child exits.
if [ -f "$SCANNER_BIN" ]; then
    cp "$SCANNER_BIN" "$APP/Contents/MacOS/DiskRoboScanner"
fi

# App icon (regenerate with: swift Scripts/generate-icon.swift)
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature (replace with Developer ID + notarization for distribution).
codesign --force --sign - "$APP"

echo "✅ Built $APP"
echo "   Note: grant Full Disk Access to Disk Robo in System Settings → Privacy & Security after first launch."
