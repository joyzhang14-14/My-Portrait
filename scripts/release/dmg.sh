#!/usr/bin/env bash
# 用 hdiutil 把 stapled .app 打成 .dmg。
# 不依赖 npm/create-dmg —— hdiutil 是 macOS 自带。
#
# 输出:
#   build/MyPortrait-<version>.dmg
#
# 版本号从 .app 的 Info.plist CFBundleShortVersionString 读。

set -euo pipefail
cd "$(dirname "$0")/../.."

APP_PATH="build/export/MyPortrait.app"
[[ -d "$APP_PATH" ]] || { echo "ERROR: $APP_PATH not found." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
DMG_NAME="MyPortrait-${VERSION}.dmg"
DMG_PATH="build/$DMG_NAME"
STAGING="build/dmg-staging"

# 1) staging 目录布局:
#    MyPortrait.app
#    Applications -> /Applications(快捷方式,用户拖进去就装好)
echo "→ stage dmg contents"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 2) 出 dmg
echo "→ hdiutil create $DMG_NAME"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "MyPortrait" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# 3) DMG 也要签名(虽然 Apple 没强制,但用户从 Gatekeeper 看到「来自已识别开发者」体验更好)
echo "→ codesign dmg"
codesign --force --sign "Developer ID Application: Zhuoyi Zhang (VYHNX2Y2AL)" \
    --timestamp \
    "$DMG_PATH"

# 4) 也可以选择性 notarize DMG(单独 notarize 一次)
# 推荐:不动 dmg notarize,因为 .app 里的 staple 已生效;dmg 是个壳。
# 如果用户不接 internet 装 dmg,Gatekeeper 仍能从 stapled .app 验。

echo ""
echo "=================================================="
echo "DMG ready: $DMG_PATH"
echo "Version:   $VERSION"
echo ""
echo "Next: scripts/release/sparkle.sh"
echo "=================================================="
