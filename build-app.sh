#!/bin/bash
# 构建 MyPortrait.xcodeproj 并**独立启动**产出的 .app。
#
# 为什么不用 Xcode ⌘R 测 capture：⌘R 把 app 跑在 Xcode debugger 之下，
# macOS TCC（屏幕录制 / 麦克风权限）会把权限请求归属到宿主 Xcode，
# My Portrait 自己永远拿不到授权条目。必须独立启动（不挂 debugger）。
#
# xcodeproj 本身已配 MyPortraitDev 自动签名 —— 这里不再手动组 bundle / 签名，
# 直接编 + open。
#
# 用法: ./build-app.sh         只构建
#       ./build-app.sh --run   构建后独立启动
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="MyPortrait.xcodeproj"
SCHEME="MyPortrait"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"

# 源文件增删后 xcodeproj 的静态文件列表会过期，先 regenerate 保险。
if command -v xcodegen >/dev/null 2>&1; then
    echo "==> xcodegen generate"
    xcodegen generate --quiet
fi

echo "==> xcodebuild ($PROJECT / $SCHEME)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -3

# 找出刚构建的 .app（按修改时间取最新）
APP=$(find "$DERIVED"/MyPortrait-*/Build/Products/Debug -maxdepth 1 -name "MyPortrait.app" \
    -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "ERROR: built MyPortrait.app not found under DerivedData"
    exit 1
fi

echo ""
echo "built: $APP"
codesign -d -r- "$APP" 2>&1 | grep -E "designated" || true

if [ "${1:-}" = "--run" ]; then
    # 杀掉可能在跑的旧实例（含 Xcode ⌘R 起的），再独立启动新的。
    pkill -f "MyPortrait.app/Contents/MacOS/MyPortrait" 2>/dev/null || true
    sleep 1
    echo "==> launching standalone (no debugger)"
    open "$APP"
fi
