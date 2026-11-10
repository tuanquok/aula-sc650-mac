#!/bin/bash
# Builds the release binary and packages "AULA SC650.app", a .zip and a .dmg into dist/.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/AULA SC650.app"
rm -rf "$APP" dist/dmgroot dist/AULA-SC650.dmg dist/AULA-SC650.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AulaApp "$APP/Contents/MacOS/AulaApp"
[ -f Assets/mouse.png ] && cp Assets/mouse.png "$APP/Contents/Resources/mouse.png" || echo "note: Assets/mouse.png not found, using the generic mouse icon (see scripts/fetch-mouse-image.sh)"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AULA SC650</string>
<key>CFBundleDisplayName</key><string>AULA SC650</string>
<key>CFBundleIdentifier</key><string>local.aula.sc650</string>
<key>CFBundleExecutable</key><string>AulaApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>AULA SC650 uses Bluetooth to configure your mouse (DPI, buttons, lighting and macros).</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
(cd dist && ditto -c -k --keepParent "AULA SC650.app" AULA-SC650.zip)
mkdir dist/dmgroot && cp -R "$APP" dist/dmgroot/ && ln -s /Applications dist/dmgroot/Applications
hdiutil create -volname "AULA SC650" -srcfolder dist/dmgroot -ov -format UDZO dist/AULA-SC650.dmg >/dev/null
rm -rf dist/dmgroot
hdiutil verify dist/AULA-SC650.dmg | tail -1
ls -la dist
