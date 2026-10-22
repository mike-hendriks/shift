#!/bin/bash
# Builds dist/Shift.app (and dist/shift-cli).
#
#   scripts/build-app.sh [--install]
#
# Environment:
#   SHIFT_VERSION   marketing version, default: latest git tag without the "v", or 0.0.0
#   SHIFT_BUILD     build number Sparkle compares, default: commit count
#   SIGN_IDENTITY   codesign identity. Default: "Shift Code Signing" when that certificate is available (see below),
#                   else "-" (ad-hoc). A "Developer ID Application: ..." identity also enables the hardened runtime
#                   and a secure timestamp, for notarization.
#   SIGNING_CERT_P12, SIGNING_CERT_PASSWORD
#                   base64 .p12 with the "Shift Code Signing" certificate (CI). Imported into a temporary keychain.
#
# Why a fixed certificate: macOS ties file access permissions (Desktop, Documents, Downloads) to the app's signature.
# Ad-hoc signatures change with every build, so every update asked for those permissions again. A self-signed
# certificate keeps the same designated requirement across builds, so permissions you grant once stay granted.
# Locally the certificate lives in ~/Library/Keychains/shift-signing.keychain-db, unlocked with the password in
# ~/.config/shift/signing-keychain-password (scripts/setup-signing.sh creates both).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${SHIFT_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="${SHIFT_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGNING_NAME="Shift Code Signing"

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

# Onboarding videos, rendered from the release film with a calm camera by promo/clips.mjs.
ditto Resources/Onboarding "$APP/Contents/Resources/Onboarding"

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

# Make the signing certificate findable: codesign only looks in keychains on the user search list, so add ours for the
# duration of the build and put the original list back afterwards.
ORIGINAL_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | xargs)
TEMP_KEYCHAIN=""
restore_keychains() {
    # shellcheck disable=SC2086
    security list-keychains -d user -s $ORIGINAL_KEYCHAINS
    [[ -n "$TEMP_KEYCHAIN" ]] && security delete-keychain "$TEMP_KEYCHAIN" 2>/dev/null || true
}
use_keychain() {
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$1" $ORIGINAL_KEYCHAINS
    trap restore_keychains EXIT
}

LOCAL_KEYCHAIN="$HOME/Library/Keychains/shift-signing.keychain-db"
LOCAL_PASSWORD="$HOME/.config/shift/signing-keychain-password"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
elif [[ -n "${SIGNING_CERT_P12:-}" ]]; then
    TEMP_KEYCHAIN="$(mktemp -d)/build.keychain-db"
    TEMP_PASSWORD=$(openssl rand -hex 16)
    security create-keychain -p "$TEMP_PASSWORD" "$TEMP_KEYCHAIN"
    security set-keychain-settings "$TEMP_KEYCHAIN"
    security unlock-keychain -p "$TEMP_PASSWORD" "$TEMP_KEYCHAIN"
    P12=$(mktemp)
    echo "$SIGNING_CERT_P12" | base64 --decode > "$P12"
    security import "$P12" -f pkcs12 -k "$TEMP_KEYCHAIN" -P "${SIGNING_CERT_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
    rm -f "$P12"
    security set-key-partition-list -S apple-tool:,apple: -s -k "$TEMP_PASSWORD" "$TEMP_KEYCHAIN" >/dev/null
    use_keychain "$TEMP_KEYCHAIN"
    IDENTITY="$SIGNING_NAME"
elif [[ -f "$LOCAL_KEYCHAIN" && -f "$LOCAL_PASSWORD" ]]; then
    security unlock-keychain -p "$(cat "$LOCAL_PASSWORD")" "$LOCAL_KEYCHAIN"
    use_keychain "$LOCAL_KEYCHAIN"
    IDENTITY="$SIGNING_NAME"
else
    echo "warning: no signing certificate, signing ad-hoc. macOS will ask for file permissions again after this build."
    IDENTITY="-"
fi

# Sign inside out: Sparkle's helpers, the framework, then the app.
SIGN_FLAGS=(--force --sign "$IDENTITY")
[[ "$IDENTITY" == Developer\ ID* ]] && SIGN_FLAGS+=(--options runtime --timestamp)
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$FW/XPCServices/Installer.xpc" "$FW/XPCServices/Downloader.xpc" "$FW/Autoupdate" "$FW/Updater.app"; do
    [[ -e "$item" ]] && codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$item"
done
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$APP"
echo "Built $APP $VERSION ($BUILD), signed with ${IDENTITY/-/ad-hoc}"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Shift || true
    # Wait for the running copy to quit, or `open` fails while it is still shutting down.
    for _ in {1..50}; do pgrep -x Shift >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/Shift.app
    cp -R "$APP" /Applications/
    open /Applications/Shift.app
    echo "Installed to /Applications/Shift.app"
fi
