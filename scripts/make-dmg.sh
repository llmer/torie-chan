#!/bin/bash
# Packages build/Torie-chan.app into build/Torie-chan-<version>.dmg (drag-to-Applications layout),
# signs and notarizes it when a Developer ID identity / notary credentials are available,
# and writes a SHA-256 checksum next to it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Torie-chan.app"
[[ -d "$APP" ]] || { echo "build $APP first (make app)"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Torie-chan-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Torie-chan.app"
ln -s /Applications "$STAGING/Applications"

echo "==> creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Torie-chan" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
fi
if [[ "${SIGN_IDENTITY:-}" == Developer\ ID* ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    scripts/notarize.sh "$DMG"
else
    echo "==> no Developer ID identity: the disk image is unsigned"
fi

(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "==> built $DMG"
