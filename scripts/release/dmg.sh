#!/usr/bin/env bash
# 用 dmgbuild 把 .app 打成 .dmg(带布局:左 app 图标 + 右 Applications 快捷方式)。
#
# 输出:
#   build/MyPortrait_<version>_arm64.dmg
#
# 版本号从 .app 的 Info.plist CFBundleShortVersionString 读。
#
# 依赖:dmgbuild + 三个 pyobjc 包,锁在 scripts/release/dmg/requirements.txt。
# 第一次跑会自动建本地 .venv 装好;以后直接复用。

set -euo pipefail
cd "$(dirname "$0")/../.."

APP_PATH="build/export/MyPortrait.app"
[[ -d "$APP_PATH" ]] || { echo "ERROR: $APP_PATH not found. Run scripts/release/build.sh first." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
DMG_NAME="MyPortrait_${VERSION}_arm64.dmg"
DMG_PATH="build/$DMG_NAME"

# 1) 准备 dmgbuild venv(只第一次跑要)
VENV="scripts/release/dmg/.venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
    echo "→ first run: creating dmgbuild venv"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --require-hashes \
        -r scripts/release/dmg/requirements.txt
fi

# 2) 找 .app 自己的 .icns 给 dmgbuild 打 volume badge
APP_ICON=""
for icns in "$APP_PATH/Contents/Resources/"*.icns; do
    [[ -f "$icns" ]] && { APP_ICON="$icns"; break; }
done

# 3) 通过环境变量 + dmgbuild_settings.py 出 .dmg
echo "→ dmgbuild $DMG_NAME"
rm -f "$DMG_PATH"
DMG_APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")" \
DMG_VOLUME_NAME="My Portrait ${VERSION}" \
DMG_BADGE_ICON="$APP_ICON" \
    "$VENV/bin/dmgbuild" \
    -s scripts/release/dmg/dmgbuild_settings.py \
    "My Portrait ${VERSION}" \
    "$DMG_PATH"

# 4) 用同一个自签 cert 签 dmg(跟 .app 一致;Gatekeeper 检 dmg 文件本身
#    的签名跟 .app 的签名同源,可以减少二次警告)
SIGN_IDENTITY="${SIGN_IDENTITY:-MyPortraitDev}"
echo "→ codesign dmg ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo ""
echo "=================================================="
echo "DMG ready: $DMG_PATH"
echo "Version:   $VERSION"
echo "Size:      $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "Next: scripts/release/sparkle.sh"
echo "=================================================="
