#!/bin/bash
# Builds dist/Shift.app (and dist/shift-cli). Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Shift
swift build -c release --product shift-cli

APP=dist/Shift.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Shift "$APP/Contents/MacOS/Shift"
cp .build/release/shift-cli dist/shift-cli

ICONSET=$(mktemp -d)/Shift.iconset
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Shift.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Shift</string>
    <key>CFBundleDisplayName</key><string>Shift</string>
    <key>CFBundleIdentifier</key><string>men.stuur.shift</string>
    <key>CFBundleExecutable</key><string>Shift</string>
    <key>CFBundleIconFile</key><string>Shift</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSpeechRecognitionUsageDescription</key><string>Shift turns speech in audio and video into Markdown, on your Mac.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Shift saves processed files to Downloads/Shift by default.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Shift || true
    # Wait for the running copy to quit, or `open` fails while it is still shutting down.
    for _ in {1..50}; do pgrep -x Shift >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/Shift.app
    cp -R "$APP" /Applications/
    open /Applications/Shift.app
    echo "Installed to /Applications/Shift.app"
fi
