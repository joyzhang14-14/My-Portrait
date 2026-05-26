#!/usr/bin/env bash
# Archive + export + **重签 ad-hoc** 出可分发的 .app。
#
# 输出:
#   build/MyPortrait.xcarchive
#   build/export/MyPortrait.app   (ad-hoc 签名 + hardened runtime + entitlements)
#
# 为什么重签 ad-hoc:
#   Xcode 默认用 Apple Development 证书(免费 Apple ID),证书绑作者本人
#   Apple ID + Team ID。在**别人**的 Mac 上 macOS TCC 认不出这条 designated
#   requirement —— 用户在系统设置里给了权限 toggle 也不解锁,onboarding 一直
#   显示 Not granted(Stan v1.0.0 反馈)。
#
#   付不起 $99/yr Developer Program → 拿不到 Developer ID,没法 notarize。
#   折中:exportArchive 出来后 codesign --sign - 重签 ad-hoc。ad-hoc 签名
#   没有 team identity,TCC 把 app 当"本机签名 untrusted",**用户 xattr -d
#   com.apple.quarantine 后能正常在系统设置里授权**。主流免费 macOS app
#   都这么干。

set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/MyPortrait.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ENTITLEMENTS="Support/MyPortrait.entitlements"

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

# 3) export(Apple Development 签名,中间产物)
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

# 4) **重签 ad-hoc** —— 关键步骤,见文件头注释。
#    --deep:递归签所有 Frameworks/ 下的 .framework / .dylib
#    --options runtime:保留 hardened runtime(entitlements 需要)
#    --entitlements:把 entitlements 重新嵌进新签名,不然 dlopen / mic 都废
#    --sign -:ad-hoc(无 identity)
#
#    --deep 先把内嵌 frameworks 整体重签,再外层 app 重签确保 sealed
#    resources hash 跟新签名对得上。
echo "→ codesign --sign - (ad-hoc re-sign, hardened runtime + entitlements)"
codesign \
    --force \
    --deep \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - \
    "$APP_PATH"

# verify 签名是 ad-hoc 而不是 Apple Development
echo "→ verify signature"
codesign --verify --deep --strict "$APP_PATH"
AUTH=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^Authority" | head -1 || true)
if [[ -n "$AUTH" ]]; then
    echo "WARN: signature still has Authority line — expected ad-hoc (none). Got: $AUTH" >&2
fi

echo ""
echo "=================================================="
echo "Built: $APP_PATH (ad-hoc signed)"
echo ""
echo "Verify signing:"
echo "  codesign -dv --entitlements - $APP_PATH"
echo "  codesign --verify --deep --strict $APP_PATH"
echo "=================================================="
