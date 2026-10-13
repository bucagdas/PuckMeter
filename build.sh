#!/bin/zsh
# Builds build/PuckMeter.app, ad-hoc signed unless SIGN_IDENTITY is set:
#   SIGN_IDENTITY="Apple Development: ..." ./build.sh
set -euo pipefail
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
cd "${0:A:h}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/PuckMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PuckMeter" "$APP/Contents/MacOS/PuckMeter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "Built $PWD/$APP"
