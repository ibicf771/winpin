#!/bin/bash
# make_dmg.sh — 将 build/Release/winpin.app 打包为 DMG
#
# 优先使用 create-dmg（brew install create-dmg）；未安装时自动回退 hdiutil 方案。
# 用法：scripts/make_dmg.sh [版本号]
#      不传版本号时，自动读取 Info.plist 的 CFBundleShortVersionString
# 产物：build/winpin-<版本号>-arm64.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Release/winpin.app"

PLIST="$ROOT/winpin/Resources/Info.plist"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
DMG="$ROOT/build/winpin-${VERSION}-arm64.dmg"
echo "==> 版本号: $VERSION"

if [[ ! -d "$APP" ]]; then
  echo "!! 未找到 $APP，请先运行 scripts/build_release.sh" >&2
  exit 1
fi

rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> 使用 create-dmg 打包"
  create-dmg \
    --volname "winpin" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "winpin.app" 150 190 \
    --app-drop-link 450 190 \
    "$DMG" \
    "$APP"
else
  echo "==> create-dmg 未安装，使用 hdiutil 兜底方案"
  STAGING="$ROOT/build/dmg_staging"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  ln -sfn /Applications "$STAGING/Applications"
  hdiutil create \
    -volname "winpin" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG"
  rm -rf "$STAGING"
fi

echo "==> 校验 DMG"
hdiutil verify "$DMG" >/dev/null && echo "hdiutil verify: OK"
ls -lh "$DMG"
echo "✅ 完成: $DMG"
