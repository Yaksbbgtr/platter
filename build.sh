#!/bin/bash
# Builds build/Platter.app (menu bar app + floating turntable + desktop widget).
# Needs Xcode and xcodegen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEGEN="$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)"

if [ ! -f App/AppIcon.icns ]; then
  swift scripts/icon.swift build/Platter.iconset
  python3 scripts/pack_icon.py build/Platter.iconset App/AppIcon.icns
fi

"$XCODEGEN" generate --quiet
rm -rf build/Platter.app
xcodebuild -project Platter.xcodeproj -scheme Platter -configuration Release \
  -derivedDataPath build/DerivedData -quiet build
cp -R build/DerivedData/Build/Products/Release/Platter.app build/

# The Now Playing adapter is loaded into /usr/bin/perl, so it ships as a plain dylib.
APP=build/Platter.app
mkdir -p "$APP/Contents/Frameworks"
xcrun swiftc -O -target "$(uname -m)-apple-macosx14.0" -emit-library -module-name PlatterNowPlaying \
  Adapter/NowPlayingAdapter.swift -o "$APP/Contents/Frameworks/libPlatterNowPlaying.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libPlatterNowPlaying.dylib"
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
