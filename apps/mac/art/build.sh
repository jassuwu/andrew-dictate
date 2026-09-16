#!/bin/zsh
# rasterize the brand from its one source, icon-source.png (ADR 0013): the app
# icon set, the menu bar badge and the bare web badge via process-icon.swift,
# the dmg volume icon via iconutil, then the og image via og-compose.swift and
# the three images apps/site serves. nothing here reads logo-character.svg —
# that is a sketch, not a build input.
set -euo pipefail
cd "$(dirname "$0")"
ICONSET=../Sources/Assets.xcassets/AppIcon.appiconset
MENUBAR=../Sources/Assets.xcassets/MenuBarBadge.imageset
SITE=../../site/public
swift process-icon.swift icon-source.png .
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
cp badge_256.png  "$SITE/favicon.png"
echo "built"
