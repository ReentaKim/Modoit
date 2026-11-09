#!/bin/bash
# 편집기 번들 → Swift 릴리스 빌드 → spike/build/ModoitSpike.app
set -euo pipefail
cd "$(dirname "$0")"

../node_modules/.bin/vite build --config editor-host/vite.config.ts --logLevel warn
swift build -c release --package-path macos
BIN="$(swift build -c release --package-path macos --show-bin-path)"

APP=build/ModoitSpike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ModoitSpike" "$APP/Contents/MacOS/"
cp -R macos/Sources/ModoitSpike/Resources/editor "$APP/Contents/Resources/editor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.reentakim.modoit.spike</string>
  <key>CFBundleName</key><string>ModoitSpike</string>
  <key>CFBundleExecutable</key><string>ModoitSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0-spike</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
du -sh "$APP"
