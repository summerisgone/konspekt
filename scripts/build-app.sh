#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=.build/Konspekt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/konspekt "$APP/Contents/MacOS/konspekt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Shown in the settings window: the release tag in CI, git describe locally.
VERSION="${KONSPEKT_VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}"
plutil -replace CFBundleShortVersionString -string "${VERSION#v}" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign -s - --force --timestamp=none "$APP"

echo "$APP"
