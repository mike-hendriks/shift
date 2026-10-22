#!/bin/bash
# Sets up the "Shift Code Signing" certificate on this Mac, so builds keep the same signature and macOS remembers the
# file permissions you grant Shift.
#
#   scripts/setup-signing.sh <shift-signing.p12> <p12 password>
#
# Creates ~/Library/Keychains/shift-signing.keychain-db with only this certificate, and stores a random password for
# it in ~/.config/shift/signing-keychain-password. Your login keychain is not touched.
set -euo pipefail
P12="${1:?usage: scripts/setup-signing.sh <shift-signing.p12> <p12 password>}"
P12_PASSWORD="${2:?usage: scripts/setup-signing.sh <shift-signing.p12> <p12 password>}"

CONFIG="$HOME/.config/shift"
KEYCHAIN="$HOME/Library/Keychains/shift-signing.keychain-db"
mkdir -p "$CONFIG" && chmod 700 "$CONFIG"
if [[ ! -f "$CONFIG/signing-keychain-password" ]]; then
    (umask 077; openssl rand -hex 24 | tr -d '\n' > "$CONFIG/signing-keychain-password")
fi
PASSWORD=$(cat "$CONFIG/signing-keychain-password")

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$P12" -f pkcs12 -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
security find-identity -p codesigning "$KEYCHAIN" | grep "Shift Code Signing"
echo "Signing set up. scripts/build-app.sh now signs with Shift Code Signing."
