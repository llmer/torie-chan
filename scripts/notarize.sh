#!/bin/bash
# Notarize and staple a signed .app (zipped for upload), .dmg or .zip.
#   scripts/notarize.sh <path>
# Credentials, either:
#   NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`>   (local)
#   NOTARY_KEY_PATH=<AuthKey.p8> NOTARY_KEY_ID=<key id> NOTARY_ISSUER=<issuer uuid> (CI, App Store Connect API key)
set -euo pipefail
TARGET="$1"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    echo "==> no notarization credentials; skipping notarization of $TARGET"
    exit 0
fi

UPLOAD="$TARGET"
if [[ "$TARGET" == *.app ]]; then
    UPLOAD="${TARGET%.app}.notarize.zip"
    ditto -c -k --keepParent "$TARGET" "$UPLOAD"
fi
echo "==> notarizing $TARGET"
xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --wait
[[ "$UPLOAD" != "$TARGET" ]] && rm -f "$UPLOAD"
xcrun stapler staple "$TARGET"
