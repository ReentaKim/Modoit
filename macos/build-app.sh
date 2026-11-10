#!/bin/bash
# 편집기 번들 → Swift 빌드 → macos/build/Modoit.app
#   ./build-app.sh            개발판(debug). 앱 ID가 .dev 라 정식판의 설정·저장 폴더를 건드리지 않는다
#   ./build-app.sh release    배포판(release, 정식 앱 ID)
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-debug}"
VERSION="2.0.0"
if [ "$MODE" = release ]; then ID=io.github.reentakim.modoit; NAME=Modoit; else ID=io.github.reentakim.modoit.dev; NAME="Modoit Dev"; VERSION="$VERSION-dev"; fi

rm -rf Sources/Modoit/Resources/editor/assets Sources/Modoit/Resources/editor/index.html
../node_modules/.bin/vite build --config editor-host/vite.config.ts --logLevel warn
swift build -c "$MODE" --product Modoit
BIN="$(swift build -c "$MODE" --show-bin-path)"

APP=build/Modoit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Modoit" "$APP/Contents/MacOS/"
cp -R Sources/Modoit/Resources/editor "$APP/Contents/Resources/editor"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>Modoit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force -s - "$APP" 2>/dev/null
du -sh "$APP"
