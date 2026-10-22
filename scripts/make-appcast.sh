#!/bin/bash
# Writes build/appcast.xml, the Sparkle update feed published with each GitHub release.
# Torie-chan reads it from releases/latest/download/appcast.xml, so it only needs the newest version.
#
#   SPARKLE_BIN=<Sparkle's bin folder> SPARKLE_KEY_FILE=<EdDSA private key> scripts/make-appcast.sh build/Torie-chan-1.2.3.dmg
#
# VERSION and BUILD_NUMBER must match the app inside the disk image (CI sets both from the tag).
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="$1"
: "${VERSION:?}" "${BUILD_NUMBER:?}" "${SPARKLE_BIN:?}" "${SPARKLE_KEY_FILE:?}"
REPO="${GITHUB_REPOSITORY:-llmer/torie-chan}"
TAG="v$VERSION"
URL="https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")"

# Prints: sparkle:edSignature="..." length="..."
SIGNATURE=$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG")
[[ "$SIGNATURE" == sparkle:edSignature=* ]] || { echo "sign_update failed" >&2; exit 1; }

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Torie-chan</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Torie-chan $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
xmllint --noout build/appcast.xml
echo "==> wrote build/appcast.xml for $VERSION ($BUILD_NUMBER)"
