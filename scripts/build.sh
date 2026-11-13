#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination=${1:-dist}
mkdir -p "$destination"
swift build --scratch-path "${HEADROOM_BUILD_DIR:-.build}" -c release
binary=$(swift build --scratch-path "${HEADROOM_BUILD_DIR:-.build}" -c release --show-bin-path)/Headroom
app="$destination/Headroom.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Headroom"
strip -S "$app/Contents/MacOS/Headroom"
cp -R ThirdParty "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.Batuhan1999.headroom</string>
<key>CFBundleName</key><string>Headroom</string>
<key>CFBundleExecutable</key><string>Headroom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Headroom modes</string><key>CFBundleURLSchemes</key><array><string>headroom</string></array></dict></array>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Headroom reads playback and battery status and controls your Sony WH-1000XM5 or WH-1000XM6 connection and power.</string>
<key>NSAudioCaptureUsageDescription</key><string>Headroom checks headphone output levels locally to detect silence. No audio is saved or sent.</string>
</dict></plist>
PLIST
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app"
printf 'Built %s\n' "$app"
