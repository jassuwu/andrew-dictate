#!/bin/zsh
# rasterize the brand from its one source, icon-source.png (ADR 0013): the app
# icon set and the menu bar badge via process-icon.swift, then the og image via
# og-compose.swift, then the three images apps/site serves. nothing here reads
# logo-character.svg — that is a sketch, not a build input.
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
swift og-compose.swift
cp og.png        "$SITE/og.png"
cp icon_1024.png "$SITE/badge.png"
cp icon_256.png  "$SITE/favicon.png"
echo "built"
