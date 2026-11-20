#!/bin/zsh
# Builds build/Platter.app with the Command Line Tools (no Xcode needed).
set -eu
cd "${0:A:h}"
APP="$PWD/build/Platter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ARCH="$(uname -m)"
swiftc Sources/Platter.swift -o "$APP/Contents/MacOS/Platter" -O -target $ARCH-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Combine
swiftc -O -target $ARCH-apple-macosx13.0 -emit-library -module-name PlatterNowPlaying \
  Adapter/NowPlayingAdapter.swift -o "$APP/Contents/Frameworks/libPlatterNowPlaying.dylib"
cp Adapter/now-playing.pl "$APP/Contents/Resources/now-playing.pl"
codesign --force --sign - "$APP/Contents/Frameworks/libPlatterNowPlaying.dylib"
swift scripts/icon.swift "$PWD/build/Platter.iconset"
python3 scripts/pack_icon.py "$PWD/build/Platter.iconset" "$APP/Contents/Resources/Platter.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Platter</string>
<key>CFBundleIdentifier</key><string>com.yaksbbgtr.platter</string>
<key>CFBundleIconFile</key><string>Platter</string>
<key>CFBundleName</key><string>Platter</string>
<key>CFBundleDisplayName</key><string>Platter</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>NSAppleEventsUsageDescription</key><string>Platter shows and controls what's playing in Music and Spotify.</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
