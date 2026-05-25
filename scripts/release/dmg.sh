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

# 3) DMG 用 Apple Development 证书签名(没付 Developer Program 年费,拿不到
#    "Developer ID Application" 证书,先用免费的 "Apple Development" 签)。
#    --timestamp 加不上(timestamp 服务器只认 Developer ID 证书),省掉。
#    用户安装时 Gatekeeper 会拦"无法验证开发者",得右键 Open 一次。
echo "→ codesign dmg (Apple Development cert, no notarize)"
codesign --force --sign "Apple Development: joyzhang_14@163.com (QCC4H9ZG7R)" \
    "$DMG_PATH"

echo ""
echo "=================================================="
echo "DMG ready: $DMG_PATH"
echo "Version:   $VERSION"
echo ""
echo "Next: scripts/release/sparkle.sh"
echo "=================================================="
