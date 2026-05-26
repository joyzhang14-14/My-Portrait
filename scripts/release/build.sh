#!/usr/bin/env bash
# Archive + export 出可分发的 .app。
#
# 输出:
#   build/MyPortrait.xcarchive
#   build/export/MyPortrait.app   (Apple Development 签名 + hardened runtime + entitlements)
#
# 签名策略:**直接用 Xcode export 出来的 Apple Development 签名,不二次重签**。
#
# 原始作者在 project.yml 里写过一条硬约束:
#   "自签名证书(无 Apple 锚定)macOS TCC 对 Screen Recording 主动拒绝
#   (auth_value 卡 0)。Apple Development 证书 DR 带 `anchor apple generic`,
#   TCC 才认。"
#
# 这条约束影响所有可选路径:
#   - 自签 keychain cert(MyPortraitDev / MyOrphiesDev 同款思路)→ ❌
#     My-Portrait 核心走 ScreenCaptureKit,自签 cert 直接被 TCC 卡 auth_value=0
#   - ad-hoc(`codesign --sign -`)→ ❌
#     DR 带 cdhash,每次 build 漂,Sparkle 跨版本判 identity 不一致拒
#   - Apple Development 证书(Xcode automatic 签)→ ✅
#     DR 带 Apple Generic anchor + cert subject,TCC 认 / 跨版本稳 / Sparkle
#     兼容 / 不要钱
#
# 没付 $99/yr Developer Program 拿不到 Developer ID + notarize,所以用户
# 下载 .dmg 第一次仍需 \`xattr -d com.apple.quarantine\` 绕 Gatekeeper。
# Sparkle 自动升级路径不走 Gatekeeper,体验透明。
#
# Stan 那种"clone 源码 Xcode 编译,在系统设置里给权限也没用"的问题,
# 已通过 Signing.local.xcconfig 让 contributor 用自己的 Apple Dev cert
# 解决(merge 自 origin/bugfix)。跟 release 路径无关。

set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/MyPortrait.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

mkdir -p "$BUILD_DIR"

# 1) regen project (确保 yml 修改进了 .xcodeproj)
echo "→ xcodegen generate"
xcodegen generate

# 2) archive
echo "→ xcodebuild archive"
xcodebuild \
    -project MyPortrait.xcodeproj \
    -scheme MyPortrait \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination "generic/platform=macOS" \
    archive | tail -20

# 3) export(Apple Development 签名,这就是最终签名,不再重签)
rm -rf "$EXPORT_DIR"
echo "→ xcodebuild exportArchive"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist scripts/release/ExportOptions.plist | tail -10

APP_PATH="$EXPORT_DIR/MyPortrait.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: expected $APP_PATH not found." >&2
    exit 1
fi

# 4) verify 签名是 Apple Development 不是 ad-hoc / 自签
echo "→ verify signature"
codesign --verify --deep --strict --verbose=1 "$APP_PATH" 2>&1 | tail -3
AUTH=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^Authority=" | head -1 | sed 's/^Authority=//')
case "$AUTH" in
    "Apple Development: "*)
        echo "  signed by: $AUTH"
        ;;
    "")
        echo "ERROR: signature has no Authority — looks like ad-hoc. Check ExportOptions.plist." >&2
        exit 1
        ;;
    *)
        echo "WARN: unexpected Authority='$AUTH' (expected 'Apple Development: ...')" >&2
        ;;
esac

echo ""
echo "=================================================="
echo "Built: $APP_PATH"
echo "Signed by: $AUTH"
echo ""
echo "Verify:"
echo "  codesign -dv --entitlements - $APP_PATH"
echo "  codesign --verify --deep --strict $APP_PATH"
echo "=================================================="
