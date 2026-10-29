#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?usage: verify-app.sh APP_PATH ZIP_PATH [development|distribution]}"
ZIP_PATH="${2:?usage: verify-app.sh APP_PATH ZIP_PATH [development|distribution]}"
VERIFY_MODE="${3:-distribution}"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

case "$VERIFY_MODE" in
    development | distribution)
        ;;
    *)
        fail "verification mode must be development or distribution"
        ;;
esac

for command_name in codesign ditto lipo plutil shasum spctl unzip xcrun; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: $command_name"
done

[ -d "$APP_PATH" ] || fail "app does not exist: $APP_PATH"
[ -f "$ZIP_PATH" ] || fail "zip does not exist: $ZIP_PATH"
APP_NAME="$(basename "$APP_PATH")"

unzip -tq "$ZIP_PATH"
ZIP_ROOT="$(unzip -Z1 "$ZIP_PATH" | sed -n '1p' | cut -d/ -f1)"
[ "$ZIP_ROOT" = "$APP_NAME" ] || fail "zip root does not contain $APP_NAME"

verify_bundle() {
    local bundle_path="$1"
    local binary_path="$bundle_path/Contents/MacOS/MacMonitor"
    local info_plist="$bundle_path/Contents/Info.plist"
    local signature

    [ -f "$info_plist" ] || fail "bundle Info.plist is missing: $bundle_path"
    [ -x "$binary_path" ] || fail "bundle executable is missing or not executable: $bundle_path"
    lipo "$binary_path" -verify_arch arm64 x86_64
    codesign --verify --deep --strict --verbose=2 "$bundle_path"

    signature="$(codesign -dv --verbose=4 "$bundle_path" 2>&1)"
    local bundle_identifier
    bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
    printf '%s\n' "$signature" | grep -F "Identifier=$bundle_identifier" >/dev/null || fail "bundle identifier is not bound to its signature"

    if [ "$VERIFY_MODE" = distribution ]; then
        printf '%s\n' "$signature" | grep -F 'Authority=Developer ID Application:' >/dev/null || fail "bundle is not signed with Developer ID Application"
        printf '%s\n' "$signature" | grep -Eq '^TeamIdentifier=.+$' || fail "bundle has no TeamIdentifier"
        printf '%s\n' "$signature" | grep -F 'Signature=adhoc' >/dev/null && fail "bundle is ad-hoc signed"
        printf '%s\n' "$signature" | grep -F 'flags=0x10000(runtime)' >/dev/null || fail "bundle is not signed with hardened runtime"
        xcrun stapler validate "$bundle_path"
        spctl --assess --type execute --verbose=4 "$bundle_path"
    fi
}

verify_bundle "$APP_PATH"

UNPACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macmonitor-verify.XXXXXX")"
trap 'rm -rf "$UNPACK_DIR"' EXIT
ditto -x -k "$ZIP_PATH" "$UNPACK_DIR"
EXTRACTED_APP="$UNPACK_DIR/$APP_NAME"
[ -d "$EXTRACTED_APP" ] || fail "zip did not extract $APP_NAME"
verify_bundle "$EXTRACTED_APP"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Contents/Info.plist")"
printf 'Verified %s (%s, %s, %s)\n' "$APP_NAME" "$VERSION" "$BUNDLE_ID" "$VERIFY_MODE"
printf 'SHA256 %s  %s\n' "$(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)" "$(basename "$ZIP_PATH")"
