#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TAG="${1:?usage: release.sh vX.Y.Z}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'ERROR: release tag must use vX.Y.Z format\n' >&2
    exit 1
}

for command_name in ditto git plutil shasum unzip xcrun; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'ERROR: missing required command: %s\n' "$command_name" >&2
        exit 1
    }
done

VERSION="${TAG#v}"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
[ "$VERSION" = "$PLIST_VERSION" ] || {
    printf 'ERROR: tag %s does not match CFBundleShortVersionString %s\n' "$TAG" "$PLIST_VERSION" >&2
    exit 1
}

git rev-parse --verify --quiet "$TAG^{commit}" >/dev/null || {
    printf 'ERROR: tag %s does not exist locally\n' "$TAG" >&2
    exit 1
}
[ "$(git rev-list -n 1 "$TAG")" = "$(git rev-parse HEAD)" ] || {
    printf 'ERROR: HEAD must match %s before release\n' "$TAG" >&2
    exit 1
}
[ -z "$(git status --porcelain)" ] || {
    printf 'ERROR: working tree must be clean before release\n' >&2
    exit 1
}

: "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required}"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${NOTARY_API_KEY_PATH:?NOTARY_PROFILE or NOTARY_API_KEY_PATH is required}"
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_API_KEY_PATH}"
    : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_API_KEY_PATH}"
    [ -f "$NOTARY_API_KEY_PATH" ] || {
        printf 'ERROR: NOTARY_API_KEY_PATH does not exist: %s\n' "$NOTARY_API_KEY_PATH" >&2
        exit 1
    }
    NOTARY_AUTH=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist/release-$VERSION}"
APP_DIR="$OUTPUT_DIR/MacMonitor.app"
ZIP_PATH="$OUTPUT_DIR/MacMonitor-$VERSION.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

"$ROOT_DIR/Scripts/run-checks.sh"
BUILD_MODE=distribution \
DEVELOPER_ID_APPLICATION="$DEVELOPER_ID_APPLICATION" \
OUTPUT_DIR="$OUTPUT_DIR" \
"$ROOT_DIR/Scripts/build-app.sh"

create_zip() {
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
}

create_zip
xcrun notarytool submit "$ZIP_PATH" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
create_zip
"$ROOT_DIR/Scripts/verify-app.sh" "$APP_DIR" "$ZIP_PATH" distribution
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf 'Release artifact: %s\n' "$ZIP_PATH"
printf 'Checksum: %s\n' "$CHECKSUM_PATH"
