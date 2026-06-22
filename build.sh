#!/bin/bash
# Build Sidecar Travel.app (ad-hoc signed). No Xcode project required.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Sidecar Travel.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "› Compiling…"
swiftc -O -parse-as-library Sources/main.swift -o "$APP/Contents/MacOS/SidecarTravel"

echo "› Generating icon…"
swift Icon/makeicon.swift build/icon_1024.png >/dev/null
rm -rf build/icon.iconset && mkdir build/icon.iconset
for sz in 16 32 64 128 256 512; do
  sips -z $sz $sz build/icon_1024.png --out "build/icon.iconset/icon_${sz}x${sz}.png" >/dev/null
  d=$((sz*2)); sips -z $d $d build/icon_1024.png --out "build/icon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
cp build/icon_1024.png build/icon.iconset/icon_512x512@2x.png
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "› Assembling bundle…"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/ctl.js "$APP/Contents/Resources/ctl.js"
cp -R Resources/en.lproj "$APP/Contents/Resources/"
cp -R Resources/sr.lproj "$APP/Contents/Resources/"

echo "› Ad-hoc signing…"
codesign --force --deep -s - "$APP"

echo "✓ Built: $APP"
