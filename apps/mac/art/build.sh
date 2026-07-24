#!/bin/zsh
# rasterize brand SVGs: app icon set + og. source of truth: logo-character.svg / og.svg
set -euo pipefail
cd "$(dirname "$0")"
ICONSET=../Sources/Assets.xcassets/AppIcon.appiconset
for size in 16 32 64 128 256 512 1024; do
  qlmanage -t -s "$size" -o . logo-character.svg >/dev/null 2>&1
  mv logo-character.svg.png "icon_${size}.png"
done
cp icon_16.png   "$ICONSET/icon_16.png"
cp icon_32.png   "$ICONSET/icon_16@2x.png"
cp icon_32.png   "$ICONSET/icon_32.png"
cp icon_64.png   "$ICONSET/icon_32@2x.png"
cp icon_128.png  "$ICONSET/icon_128.png"
cp icon_256.png  "$ICONSET/icon_128@2x.png"
cp icon_256.png  "$ICONSET/icon_256.png"
cp icon_512.png  "$ICONSET/icon_256@2x.png"
cp icon_512.png  "$ICONSET/icon_512.png"
cp icon_1024.png "$ICONSET/icon_512@2x.png"
qlmanage -t -s 1200 -o . og.svg >/dev/null 2>&1
mv og.svg.png og.png
echo "built"
