#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release

APP_DIR="dist/MacMonitor.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/MacMonitor "$APP_DIR/Contents/MacOS/MacMonitor"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon.png "$APP_DIR/Contents/Resources/AppIcon.png"
chmod +x "$APP_DIR/Contents/MacOS/MacMonitor"

printf '%s\n' "$ROOT_DIR/$APP_DIR"
