#!/bin/zsh
# rasterize the brand from its two drawings, logo.svg and its small cut
# logo-small.svg (ADR 0013): the app icon set, the menu bar badge, the in-app
# badge and the web images via process-icon.swift, the dmg volume icon via
# iconutil, then the og image via og-compose.swift and the four images
# apps/site serves.
set -euo pipefail
cd "$(dirname "$0")"
ICONSET=../Sources/Assets.xcassets/AppIcon.appiconset
MENUBAR=../Sources/Assets.xcassets/MenuBarBadge.imageset
BADGE=../Sources/Assets.xcassets/Badge.imageset
SITE=../../site/public
swift process-icon.swift . .
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
cp menubar_18.png menubar_36.png "$MENUBAR/"
cp badge_512.png badge_1024.png "$BADGE/"

# the dmg volume icon — the first icon anyone ever sees (release.yml copies it
# in as .VolumeIcon.icns). built here so it cannot drift from the app icon.
TMP="$(mktemp -d)"
STAGE="$TMP/AndrewDictate.iconset"
mkdir -p "$STAGE"
cp icon_16.png   "$STAGE/icon_16x16.png"
cp icon_32.png   "$STAGE/icon_16x16@2x.png"
cp icon_32.png   "$STAGE/icon_32x32.png"
cp icon_64.png   "$STAGE/icon_32x32@2x.png"
cp icon_128.png  "$STAGE/icon_128x128.png"
cp icon_256.png  "$STAGE/icon_128x128@2x.png"
cp icon_256.png  "$STAGE/icon_256x256.png"
cp icon_512.png  "$STAGE/icon_256x256@2x.png"
cp icon_512.png  "$STAGE/icon_512x512.png"
cp icon_1024.png "$STAGE/icon_512x512@2x.png"
iconutil -c icns "$STAGE" -o AndrewDictate.icns
rm -rf "$TMP"

swift og-compose.swift
cp og.png        "$SITE/og.png"
cp badge_1024.png "$SITE/badge.png"
cp favicon_256.png "$SITE/favicon.png"
# a png under the old name, for whatever asks for /favicon.ico unprompted
cp favicon_32.png  "$SITE/favicon.ico"
# the badge as the menu bar wears it, for the menu bar the site draws
cp menubar_36.png "$SITE/menubar.png"
echo "built"
