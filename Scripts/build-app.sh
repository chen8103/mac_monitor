#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_MODE="${BUILD_MODE:-development}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.build/release-universal}"
APP_NAME="${APP_NAME:-MacMonitor}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.0}"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

case "$BUILD_MODE" in
    development)
        ;;
    distribution)
        : "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required for distribution builds}"
        command -v security >/dev/null 2>&1 || fail "security is required for distribution signing"
        if ! security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null; then
            fail "the requested Developer ID identity is not installed: $DEVELOPER_ID_APPLICATION"
        fi
        ;;
    *)
        fail "BUILD_MODE must be development or distribution"
        ;;
esac

for command_name in swift lipo codesign plutil; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: $command_name"
done

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
printf 'Building %s %s (%s)\n' "$APP_NAME" "$VERSION" "$BUILD_MODE" >&2

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

build_architecture() {
    local architecture="$1"
    local triple="${architecture}-apple-macosx${MIN_MACOS_VERSION}"
    local scratch_path="$BUILD_ROOT/$architecture"
    local binary_path

    printf 'Building %s (%s)\n' "$architecture" "$triple" >&2
    swift build \
        --configuration release \
        --triple "$triple" \
        --scratch-path "$scratch_path" >&2
    binary_path="$(swift build \
        --configuration release \
        --triple "$triple" \
        --scratch-path "$scratch_path" \
        --show-bin-path)/$APP_NAME"
    [ -x "$binary_path" ] || fail "SwiftPM did not produce $binary_path"
    printf '%s\n' "$binary_path"
}

arm64_binary="$(build_architecture arm64)"
x86_64_binary="$(build_architecture x86_64)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

bundle_binary="$APP_DIR/Contents/MacOS/$APP_NAME"
lipo -create "$arm64_binary" "$x86_64_binary" -output "$bundle_binary"
lipo "$bundle_binary" -verify_arch arm64 x86_64

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/AppIcon.png" "$APP_DIR/Contents/Resources/AppIcon.png"
chmod 755 "$bundle_binary"

if [ "$BUILD_MODE" = distribution ]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$bundle_binary"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP_DIR"
else
    codesign --force --sign - "$bundle_binary"
    codesign --force --sign - "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

printf 'Bundle identifier: %s\n' "$BUNDLE_ID" >&2
printf 'Architectures: ' >&2
lipo -info "$bundle_binary" >&2
printf 'Signed bundle: %s\n' "$APP_DIR" >&2
printf '%s\n' "$APP_DIR"
