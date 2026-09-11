#!/bin/sh
set -eu
cd "$(dirname "$0")"
ICONSET=".build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/icon-source.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/icon-source.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
sips -z 32 32 Assets/icon-source.png --out Assets/favicon.png >/dev/null
sips -s format ico Assets/favicon.png --out Assets/favicon.ico >/dev/null
