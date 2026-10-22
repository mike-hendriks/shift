#!/bin/bash
# Builds dist/Shift.app (and dist/shift-cli).
#
#   scripts/build-app.sh [--install]
#
# Environment:
#   SHIFT_VERSION   marketing version, default: latest git tag without the "v", or 0.0.0
#   SHIFT_BUILD     build number Sparkle compares, default: commit count
#   SIGN_IDENTITY   codesign identity, default "-" (ad-hoc). Set a "Developer ID Application: ..." identity to sign for
#                   notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${SHIFT_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="${SHIFT_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${SIGN_IDENTITY:--}"

FEED_URL="https://github.com/mike-hendriks/shift/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="8cbyHQr8nxOIGmhd3DFpYUU5eZUZ3C+KW5mAIRpHa2Y="

swift build -c release --product Shift
swift build -c release --product shift-cli

APP=dist/Shift.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Shift "$APP/Contents/MacOS/Shift"
cp .build/release/shift-cli dist/shift-cli

# Sparkle ships as a binary framework; SwiftPM puts a copy next to the build products.
SPARKLE=.build/release/Sparkle.framework
[[ -d "$SPARKLE" ]] || SPARKLE=$(find .build/artifacts -path "*macos*/Sparkle.framework" -maxdepth 6 | head -1)
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

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
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSpeechRecognitionUsageDescription</key><string>Shift turns speech in audio and video into Markdown, on your Mac.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Shift saves processed files to Downloads/Shift by default.</string>
    <key>SUFeedURL</key><string>${FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Sign inside out: Sparkle's helpers, the framework, then the app.
SIGN_FLAGS=(--force --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--options runtime --timestamp)
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$FW/XPCServices/Installer.xpc" "$FW/XPCServices/Downloader.xpc" "$FW/Autoupdate" "$FW/Updater.app"; do
    [[ -e "$item" ]] && codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$item"
done
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$APP"
echo "Built $APP $VERSION ($BUILD)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Shift || true
    # Wait for the running copy to quit, or `open` fails while it is still shutting down.
    for _ in {1..50}; do pgrep -x Shift >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/Shift.app
    cp -R "$APP" /Applications/
    open /Applications/Shift.app
    echo "Installed to /Applications/Shift.app"
fi
