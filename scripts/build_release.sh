#!/bin/bash
# build_release.sh — 编译 winpin (Release/arm64) 并组装 ad-hoc 签名的 winpin.app
#
# 主路径：xcodebuild -project winpin.xcodeproj（产出完整 .app Bundle）
# 兜底路径：swift build --disable-sandbox + 手工组装 Bundle
#   （某些受限 shell 环境无法执行 xcodebuild 的嵌套 sandbox 时使用）
#
# 用法：scripts/build_release.sh
# 产物：build/Release/winpin.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/Release/winpin.app"

build_with_xcodebuild() {
  echo "==> [xcodebuild] 编译 (Release, arm64)"
  xcodebuild \
    -project winpin.xcodeproj \
    -scheme winpin \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
    clean build
}

build_with_swiftpm() {
  echo "==> [swift build] 兜底编译 (release, arm64)"
  swift build --disable-sandbox -c release --arch arm64
  local bin
  bin="$(swift build --disable-sandbox -c release --arch arm64 --show-bin-path)/winpin"
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  cp "$bin" "$APP_DIR/Contents/MacOS/winpin"
  cp "$ROOT/winpin/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
}

if ! build_with_xcodebuild; then
  echo "!! xcodebuild 失败，回退 swift build 兜底路径" >&2
  build_with_swiftpm
fi

echo "==> ad-hoc 签名（--deep，含 entitlements）"
codesign --force --deep --sign - \
  --entitlements "$ROOT/winpin.entitlements" \
  --identifier com.winpin.app \
  "$APP_DIR"

echo "==> 校验"
file "$APP_DIR/Contents/MacOS/winpin"
codesign -dv --verbose=2 "$APP_DIR" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" || true

echo "✅ 完成: $APP_DIR"
