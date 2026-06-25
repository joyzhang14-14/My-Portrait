#!/usr/bin/env bash
# Archive + export + **用本地自签 cert 重签** 出可分发的 .app。
#
# 输出:
#   build/MyPortrait.xcarchive
#   build/export/MyPortrait.app   (MyPortraitDev 签名 + hardened runtime + entitlements)
#
# 签名策略:本地自签 keychain cert(MyPortraitDev),跟 My-Smart-Bar /
# My-Orphies 同款方案。
#
# 为啥不用 Apple Development cert:
#   - 绑你 Apple ID。哪天免费 dev 账号 expired / 你换账号,签名身份就丢
#   - 签名里直接暴露作者邮箱(joyzhang_14@163.com),用户 codesign -dvvv 看得到
#
# 为啥不用 ad-hoc(`codesign --sign -`):
#   - DR 带 cdhash,每次 build 漂。Sparkle 跨版本判 identity 不一致拒
#
# 为啥自签 cert 没问题(原始 project.yml 注释"自签 cert macOS TCC 卡
# Screen Recording auth_value=0"是误判 / 过时):
#   - My-Orphies 用 MyOrphiesDev 自签 cert,Screen Recording 实际能给+生效
#   - macOS 15+ 对 self-signed code signing identity 不再有 Screen Recording
#     特殊歧视;只要 Hardened Runtime + entitlements + NSScreenCaptureUsage-
#     Description 都对,跟 Apple Dev cert 待遇一样
#
# 一次性建 cert(本机做一次):
#   Keychain Access → Certificate Assistant → Create a Certificate
#     Name: MyPortraitDev
#     Identity Type: Self Signed Root
#     Certificate Type: Code Signing
#   建完后 trust 设成"Always Trust"(右键 → Get Info → Trust)。
#
# 用户下载 .dmg 第一次开仍需 \`xattr -d com.apple.quarantine\` 绕 Gatekeeper
# (没付 $99/yr 拿不到 Developer ID + notarize)。Sparkle 自动升级路径**不走
# Gatekeeper**,升级体验透明。

set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/MyPortrait.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ENTITLEMENTS="Support/MyPortrait.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-MyPortraitDev}"

# verify cert exists in keychain before doing anything else
if ! security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
    echo "ERROR: codesigning identity '$SIGN_IDENTITY' not found in keychain." >&2
    echo "       Open Keychain Access → Certificate Assistant → Create a Certificate" >&2
    echo "       (Self Signed Root + Code Signing). Or set SIGN_IDENTITY=<name>." >&2
    exit 1
fi

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
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    archive | tail -20

# 3) export(Apple Development 签名,作为中间产物;下一步会用自签 cert 重签)
rm -rf "$EXPORT_DIR"; mkdir -p "$EXPORT_DIR"
# ⚠️ Xcode 16 的 xcodebuild -exportArchive 对自签(无 Developer ID)app 失效:
#    "method" 无任何可用值,报 `expected one {} but found development/debugging`。
#    但 export 本就只为把 .app 从 archive 取出来(下一步会用 MyPortraitDev 重签),
#    所以直接 copy archive 里的 .app,绕过坏掉的 exportArchive。ExportOptions.plist 不再用。
echo "→ copy .app from archive (绕过 Xcode16 坏掉的 exportArchive)"
cp -R "$ARCHIVE/Products/Applications/MyPortrait.app" "$EXPORT_DIR/"

APP_PATH="$EXPORT_DIR/MyPortrait.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: expected $APP_PATH not found." >&2
    exit 1
fi

# 4) 重签:从内向外。Sparkle.framework 内嵌的 XPC services + Updater.app
#    有自己的 entitlements,要 --preserve-metadata 保留;最后外层 app
#    覆盖完整 entitlements。--options runtime 全程保留 hardened runtime。
echo "→ codesign --sign $SIGN_IDENTITY (recursive, hardened runtime)"

SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    # Sparkle 的 4 个内嵌可执行体 —— 每个要单独签,顺序"最深的先签"
    for path in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Updater.app"; do
        if [[ -d "$path" ]]; then
            codesign --force --options runtime \
                --preserve-metadata=entitlements \
                --sign "$SIGN_IDENTITY" \
                "$path"
        fi
    done
    if [[ -f "$SPARKLE/Versions/B/Autoupdate" ]]; then
        codesign --force --options runtime --sign "$SIGN_IDENTITY" \
            "$SPARKLE/Versions/B/Autoupdate"
    fi
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE"
fi

# 其他 .framework(onnxruntime 等)—— 没自己的 entitlements,直接整体签
for fw in "$APP_PATH/Contents/Frameworks/"*.framework; do
    [[ -d "$fw" ]] || continue
    name="$(basename "$fw")"
    [[ "$name" == "Sparkle.framework" ]] && continue   # 已单独处理
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$fw"
done

# 5) 最后签主 app 外壳 —— 带我们的 entitlements。这步必须最后做,
#    因为前面内嵌组件改了 sealed resources 哈希。
codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

# 6) verify 签名链
echo "→ verify signature chain"
codesign --verify --deep --strict --verbose=1 "$APP_PATH" 2>&1 | tail -5

# 验证 Authority 是 MyPortraitDev 不是 Apple Dev 残留
AUTH=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^Authority=" | head -1 | sed 's/^Authority=//')
if [[ "$AUTH" != "$SIGN_IDENTITY" ]]; then
    echo "ERROR: expected Authority='$SIGN_IDENTITY', got '$AUTH'" >&2
    exit 1
fi

echo ""
echo "=================================================="
echo "Built: $APP_PATH"
echo "Signed by: $AUTH (self-signed, TCC/Sparkle-stable)"
echo ""
echo "Verify:"
echo "  codesign -dv --entitlements - $APP_PATH"
echo "  codesign --verify --deep --strict $APP_PATH"
echo "=================================================="
