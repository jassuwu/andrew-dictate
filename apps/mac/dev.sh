#!/usr/bin/env bash
# Build the development app, sign it with a stable identity, and run it.
#
# Why this exists: a debug build used to be indistinguishable from the shipped
# app to macOS — same bundle id, same name, same folder — so the two fought over
# one set of TCC grants and one archive. Testing a change meant cutting a
# release and installing it on a second mac.
#
# Three things make that unnecessary:
#   * the Debug configuration builds "Andrew Dictate Dev" as gg.jass.dictate.dev,
#     so it has its own permissions, its own settings and its own data
#   * it is signed with a *stable* identity, so its designated requirement does
#     not change between builds and the grants survive a rebuild
#   * it is installed to a fixed path rather than run out of DerivedData, whose
#     path changes and takes the grants with it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Andrew Dictate Dev"
INSTALL_PATH="/Applications/${APP_NAME}.app"
DERIVED=".build-dev"

# An Apple Development certificate is ideal: it is stable across rebuilds, which
# is the whole point. Ad-hoc still works, but macOS will re-ask for
# accessibility every single build, which is the friction this script exists to
# remove — so say so rather than letting it be a mystery.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "!! no Apple Development certificate found — signing ad-hoc."
  echo "!! macOS will ask for accessibility again after every build."
  echo "!! fix: Xcode ▸ Settings ▸ Accounts ▸ add your Apple ID (free)."
  echo
fi

echo "▸ generating project"
xcodegen generate --quiet

echo "▸ building Debug   (signing as: ${IDENTITY})"
xcodebuild build \
  -project AndrewDictate.xcodeproj \
  -scheme AndrewDictate \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  -quiet

BUILT="${DERIVED}/Build/Products/Debug/${APP_NAME}.app"
[ -d "$BUILT" ] || { echo "build produced no app at ${BUILT}"; exit 1; }

# Sign explicitly rather than trusting the build setting: --deep covers the
# bundled frameworks, and a partially signed bundle reads as a changed identity.
codesign --force --deep -s "$IDENTITY" "$BUILT" 2>/dev/null

echo "▸ installing to ${INSTALL_PATH}"
osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
pkill -f "${APP_NAME}.app" 2>/dev/null || true
rm -rf "$INSTALL_PATH"
cp -R "$BUILT" "$INSTALL_PATH"

echo "▸ launching"
open "$INSTALL_PATH"

cat <<NOTE

running: ${APP_NAME}  (gg.jass.dictate.dev)
  data:  ~/Library/Application Support/Andrew Dictate Dev/
  logs:  log stream --predicate 'subsystem == "gg.jass.dictate.dev"'

the shipped app is untouched — separate permissions, separate archive.
NOTE
