#!/bin/bash
# Builds "Torie-chan.app" into ./build and signs it.
#
#   scripts/build-app.sh            # release build, signed with your first Apple Development identity
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=bg scripts/build-app.sh   # + notarize & staple
#
# Notarization credentials: see scripts/notarize.sh (keychain profile locally, API key in CI).
# VERSION / BUILD_NUMBER override the bundle version (CI sets them from the release tag).
#
# The lid-close helper (SMAppService daemon) needs a real team-signed build; an ad-hoc
# signature still runs everything else.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Torie-chan.app"
HELPER_LABEL="com.mostperfectsip.toriechan.helper"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Version from the release tag in CI (VERSION=1.2.3, BUILD_NUMBER=42); local builds keep the plist's.
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$BIN/TorieChan" "$BIN/bg-mcp" "$BIN/bg-helper" "$APP/Contents/MacOS/"
# Sparkle (auto-updates). Torie-chan isn't sandboxed, so Sparkle's XPC services aren't used: leave them out.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp "Resources/$HELPER_LABEL.plist" "$APP/Contents/Library/LaunchDaemons/"

echo "==> signing with: $SIGN_IDENTITY"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)        # notarization requires a secure timestamp
elif [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp=none)   # local development builds
fi
# Inside out: Sparkle's helpers, then the framework, then our executables, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE"
codesign "${SIGN_ARGS[@]}" --identifier "$HELPER_LABEL" "$APP/Contents/MacOS/bg-helper"
codesign "${SIGN_ARGS[@]}" --identifier "com.mostperfectsip.toriechan.mcp" "$APP/Contents/MacOS/bg-mcp"
codesign "${SIGN_ARGS[@]}" --entitlements Resources/TorieChan.entitlements "$APP"
codesign --verify --strict --deep "$APP"

if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    scripts/notarize.sh "$APP"
fi

echo "==> built $APP"
