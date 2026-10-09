#!/bin/bash
# Assemble le .app à partir du binaire SwiftPM + Info.plist + signature ad-hoc.
set -e
cd "$(dirname "$0")"
BIN=".build/debug/TchouTchou"
APP="build/TchouTchou.app"

swift build
mkdir -p "$APP/Contents/MacOS"
cp TchouTchou/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable TchouTchou" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.TchouTchou" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName TchouTchou" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp TchouTchou/Assets.xcassets/AppIcon.appiconset/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in TchouTchou/Resources/*.lproj; do
  rm -rf "$APP/Contents/Resources/$(basename "$lproj")"
  cp -R "$lproj" "$APP/Contents/Resources/"
done
cp "$BIN" "$APP/Contents/MacOS/TchouTchou"
rm -rf "$APP/Contents/_CodeSignature"
codesign --force --sign - "$APP"
echo "✅ $APP prêt"
