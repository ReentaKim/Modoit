#!/bin/bash
# 배포판을 빌드해 dmg로 묶는다 → macos/build/Modoit-<버전>.dmg (D-11: 서명·공증 없음, ad-hoc 서명만)
#   macos/make-dmg.sh
# 만들기만 한다. 올리기(GitHub Release, Homebrew)는 따로 한다.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build-app.sh)
APP=build/release/Modoit.app
DMG=build/Modoit-$VERSION.dmg
mkdir -p build/release
OUT="$APP" ./build-app.sh release
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Modoit.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Modoit $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --verify --deep "$APP" && echo "서명 확인: ad-hoc"
shasum -a 256 "$DMG"
du -sh "$DMG"
