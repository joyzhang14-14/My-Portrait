#!/usr/bin/env bash
# 提交 .app 给 Apple notarize + staple ticket。
#
# 环境变量(用 keychain profile 存,只一次):
#   APPLE_ID         你的 Apple ID(joyzhang_14@163.com)
#   APPLE_TEAM_ID    VYHNX2Y2AL
#   APPLE_APP_PWD    App-specific password(appleid.apple.com 生成)
#
# 第一次跑前:
#   xcrun notarytool store-credentials NOTARY_PROFILE \
#       --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
#       --password "$APPLE_APP_PWD"
#
# 之后这个脚本只用 --keychain-profile NOTARY_PROFILE 即可。

set -euo pipefail
cd "$(dirname "$0")/../.."

APP_PATH="build/export/MyPortrait.app"
ZIP_PATH="build/MyPortrait.notarize.zip"
PROFILE="${NOTARY_PROFILE:-NOTARY_PROFILE}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: $APP_PATH not found. Run scripts/release/build.sh first." >&2
    exit 1
fi

# 1) zip(notarytool 要 zip / dmg / pkg)
echo "→ zip for notarize"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# 2) submit + wait
echo "→ notarytool submit (profile: $PROFILE)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$PROFILE" \
    --wait

# 3) staple ticket 进 .app(zip 是临时的,只对 .app staple)
echo "→ stapler staple"
xcrun stapler staple "$APP_PATH"

# 4) 验证
echo "→ verify"
xcrun stapler validate "$APP_PATH"
spctl -a -t exec -vv "$APP_PATH" || true   # spctl exit code 即使通过也可能 ≠0,看输出

echo ""
echo "=================================================="
echo "Notarized + stapled: $APP_PATH"
echo ""
echo "Next: scripts/release/dmg.sh"
echo "=================================================="
