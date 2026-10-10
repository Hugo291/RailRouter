#!/bin/bash
# Assemble le .app à partir du binaire SwiftPM + Info.plist + signature ad-hoc.
set -e
cd "$(dirname "$0")"
BIN=".build/debug/RailRouter"
APP="build/RailRouter.app"

swift build
mkdir -p "$APP/Contents/MacOS"
cp RailRouter/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable RailRouter" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.RailRouter" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName RailRouter" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp RailRouter/Assets.xcassets/AppIcon.appiconset/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in RailRouter/Resources/*.lproj; do
  rm -rf "$APP/Contents/Resources/$(basename "$lproj")"
  cp -R "$lproj" "$APP/Contents/Resources/"
done
rm -rf "$APP/Contents/Resources/Providers"
cp -R RailRouter/Resources/Providers "$APP/Contents/Resources/Providers"
cp "$BIN" "$APP/Contents/MacOS/RailRouter"
rm -rf "$APP/Contents/_CodeSignature"
codesign --force --sign - "$APP"
echo "✅ $APP prêt"
