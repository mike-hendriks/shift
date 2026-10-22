#!/bin/bash
# Builds a release: dist/Shift-<version>.dmg plus dist/appcast.xml, the Sparkle update feed.
#
#   scripts/release.sh 0.2.0            build and sign locally, publish nothing
#   scripts/release.sh 0.2.0 --publish  also create the GitHub release v0.2.0 with both files
#
# The update signature uses the Sparkle EdDSA key: from $SPARKLE_PRIVATE_KEY (CI), else from your login keychain.
# Installed copies of Shift read the appcast from the latest release, so publishing a release updates everyone.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
VERSION="${VERSION#v}"
PUBLISH="${2:-}"
TAG="v$VERSION"
REPO="mike-hendriks/shift"
SPARKLE_VERSION="2.10.0"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3, got $VERSION"; exit 1; }

# Sparkle's command line tools sign the update; they ship in the Sparkle release, not in the Swift package.
TOOLS=.build/sparkle-tools
if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
    mkdir -p "$TOOLS"
    curl -sSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        | tar -xJ -C "$TOOLS"
fi

BUILD=$(git rev-list --count HEAD)
SHIFT_VERSION="$VERSION" SHIFT_BUILD="$BUILD" scripts/build-app.sh

# Disk image: the app plus a shortcut to Applications to drag it onto.
DMG="dist/Shift-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto dist/Shift.app "$STAGE/Shift.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Shift $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

sign() {
    if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
        echo "$SPARKLE_PRIVATE_KEY" | "$TOOLS/bin/sign_update" --ed-key-file - "$@"
    else
        "$TOOLS/bin/sign_update" "$@"
    fi
}
ENCLOSURE_SIGNATURE=$(sign "$DMG")   # sparkle:edSignature="..." length="..."

# Release notes: commit titles since the previous tag.
PREVIOUS=$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || git describe --tags --abbrev=0 2>/dev/null || true)
[[ "$PREVIOUS" == "$TAG" ]] && PREVIOUS=""
RANGE=${PREVIOUS:+$PREVIOUS..}HEAD
NOTES=$(git log --no-merges --format='%s' "$RANGE" | grep -v '^Merge' || true)
[[ -z "$NOTES" ]] && NOTES="First release"
NOTES_MD=$(echo "$NOTES" | sed 's/^/- /')
NOTES_HTML="<ul>$(echo "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|^|<li>|' -e 's|$|</li>|' | tr -d '\n')</ul>"

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Shift</title>
    <link>https://github.com/$REPO</link>
    <description>Shift updates</description>
    <language>en</language>
    <item>
      <title>Shift $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Shift-$VERSION.dmg" $ENCLOSURE_SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
# Sign the feed itself as well; the signature is embedded as an XML comment.
sign dist/appcast.xml >/dev/null

echo "Release $VERSION ($BUILD) ready:"
echo "  $DMG"
echo "  dist/appcast.xml"

if [[ "$PUBLISH" == "--publish" ]]; then
    gh release create "$TAG" "$DMG" dist/appcast.xml --repo "$REPO" --title "Shift $VERSION" \
        --notes "$(printf '%s\n\n%s' "$NOTES_MD" "Download **Shift-$VERSION.dmg**, open it and drag Shift to Applications. Installed copies update themselves.")"
    echo "Published https://github.com/$REPO/releases/tag/$TAG"
fi
