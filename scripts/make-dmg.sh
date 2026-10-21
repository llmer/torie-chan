#!/bin/bash
# Packages build/Torie-chan.app into build/Torie-chan-<version>.dmg:
#   - Torie-chan's icon as the volume icon
#   - a styled window: drawn background, app on the left, Applications on the right
# then signs and notarizes it when a Developer ID identity / notary credentials are available,
# and writes a SHA-256 checksum next to it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Torie-chan.app"
[[ -d "$APP" ]] || { echo "build $APP first (make app)"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Torie-chan-$VERSION.dmg"
RW="build/Torie-chan-rw.dmg"
VOLNAME="Torie-chan"

STAGING="$(mktemp -d)"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" && -d "$MOUNT" ]] && hdiutil detach -force -quiet "$MOUNT" || true
    rm -rf "$STAGING"
    rm -f "$RW"
}
trap cleanup EXIT

echo "==> staging"
ditto "$APP" "$STAGING/Torie-chan.app"
ln -s /Applications "$STAGING/Applications"

# Window background, drawn by the same renderer as the app icon (1x + 2x in one TIFF).
mkdir -p "$STAGING/.background"
if [[ ! -x build/make-icon || scripts/icon/main.swift -nt build/make-icon ]]; then
    swiftc -O -swift-version 5 Sources/TorieChan/UI/EyesView.swift Sources/TorieChan/UI/EyesModel.swift \
        Sources/TorieChan/Sensors/PersonTracker.swift scripts/icon/main.swift -o build/make-icon
fi
build/make-icon "$STAGING/bg.png" dmg
build/make-icon "$STAGING/bg@2x.png" dmg@2x
tiffutil -cathidpicheck "$STAGING/bg.png" "$STAGING/bg@2x.png" -out "$STAGING/.background/background.tiff" 2>/dev/null
rm "$STAGING/bg.png" "$STAGING/bg@2x.png"

echo "==> creating writable image"
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 20 ))
rm -f "$RW"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov -quiet "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"
[[ -d "$MOUNT" ]] || { echo "could not mount $RW"; exit 1; }
DISK_NAME="$(basename "$MOUNT")" # "Torie-chan", or "Torie-chan 1" if one is already mounted

echo "==> laying out the window"
if ! osascript <<EOF
tell application "Finder"
    tell disk "$DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Torie-chan.app" of container window to {170, 190}
        set position of item "Applications" of container window to {490, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "warning: Finder layout failed (no Automation access?); the disk image keeps its icon but uses a plain window"
fi

# Volume icon last: hdiutil drops a staged .VolumeIcon.icns, and Finder rewrites the volume's
# Finder info when the layout window closes, which clears the custom-icon flag.
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null; then
    SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"
else
    xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
fi

chmod -Rf go-w "$MOUNT" || true
sync
for _ in 1 2 3 4 5; do
    hdiutil detach -quiet "$MOUNT" && MOUNT="" && break
    sleep 2
done
[[ -z "$MOUNT" ]] || { hdiutil detach -force -quiet "$MOUNT"; MOUNT=""; }

echo "==> compressing to $DMG"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"

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
