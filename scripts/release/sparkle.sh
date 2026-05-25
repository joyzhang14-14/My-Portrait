#!/usr/bin/env bash
# Sparkle 签名 + appcast.xml 生成。
#
# 输入:  build/MyPortrait-<version>.dmg
# 输出:  打印一条 appcast item XML(贴进 docs/appcast.xml),手动 commit + push
#
# 流程:
#   1. sign_update 用 keychain 里的私钥签 dmg → ed_signature
#   2. 拿 dmg 大小(bytes)
#   3. 拼一段 <item> XML 输出

set -euo pipefail
cd "$(dirname "$0")/../.."

DMG_GLOB="build/MyPortrait-*.dmg"
DMG_PATH=$(ls -t $DMG_GLOB 2>/dev/null | head -1 || true)
[[ -n "$DMG_PATH" && -f "$DMG_PATH" ]] || {
    echo "ERROR: no DMG found in build/. Run scripts/release/dmg.sh first." >&2
    exit 1
}

# sign_update —— Sparkle SPM 装出的产物在 DerivedData 里。
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
SIGN_UPDATE=$(find "$DERIVED" -name "sign_update" -type f 2>/dev/null | head -1 || true)
if [[ -z "$SIGN_UPDATE" ]]; then
    if command -v sign_update >/dev/null 2>&1; then
        SIGN_UPDATE=$(command -v sign_update)
    else
        echo "ERROR: sign_update not found." >&2
        echo "  brew install --cask sparkle, or build via Xcode once." >&2
        exit 1
    fi
fi

VERSION=$(basename "$DMG_PATH" .dmg | sed 's/MyPortrait-//')
SIZE=$(stat -f%z "$DMG_PATH")
SIG=$("$SIGN_UPDATE" "$DMG_PATH")

# GitHub release URL —— 上传 DMG 到对应 tag 的 release 之后才存在。
TAG="v${VERSION}"
DOWNLOAD_URL="https://github.com/joyzhang14-14/My-Portrait/releases/download/${TAG}/$(basename "$DMG_PATH")"

PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat <<EOF

==================================================
Sparkle appcast item:
==================================================

        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <ul>
                    <li>TODO: fill in release notes</li>
                </ul>
            ]]></description>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${SIZE}"
                type="application/octet-stream"
                ${SIG} />
        </item>

==================================================
Next:
  1. Paste this <item> into docs/appcast.xml (under <channel>, above existing items)
  2. Commit docs/appcast.xml + push (GitHub Pages will pick it up)
  3. Create GitHub release tagged ${TAG} with $(basename "$DMG_PATH") attached
==================================================
EOF
