#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
sh build-icons.sh
APP="dist/DuoIcon.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/favicon.ico "$APP/Contents/Resources/favicon.ico"
cp .build/release/DuoIcon "$APP/Contents/MacOS/DuoIcon"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s/%s\n' "$PWD" "$APP"
