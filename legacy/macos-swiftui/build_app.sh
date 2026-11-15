#!/bin/bash
# Builds DupeSweep.app into ./build  (macOS 12+, Command Line Tools with Swift 5.7 or newer).
# Uses swiftc directly, so a broken SwiftPM / PackageDescription install doesn't matter.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DupeSweep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compiling (release, $(uname -m))…"
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macosx12.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Sources/DupeSweep/*.swift \
  -o "$APP/Contents/MacOS/DupeSweep"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DupeSweep</string>
  <key>CFBundleIdentifier</key><string>com.malik.dupesweep</string>
  <key>CFBundleName</key><string>DupeSweep</string>
  <key>CFBundleDisplayName</key><string>DupeSweep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "✅ BUILD OK: $(pwd)/$APP"
echo "   Run:       open \"$APP\""
echo "   Self-test: \"$APP/Contents/MacOS/DupeSweep\" --selftest ~/Pictures/SomeFolder"
