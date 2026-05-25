#!/usr/bin/env bash
# Sparkle EdDSA 密钥对生成。运行一次,以后再发布只 sign_update,不用重跑。
#
# 行为(取决于 Sparkle 版本):
#   - 私钥存进 macOS Keychain(service "https://sparkle-project.org")
#   - 公钥打印到 stdout —— 复制贴到 project.yml 的 SUPublicEDKey
#
# 公钥被嵌进 binary 验证 appcast 真伪。私钥用于发布时签名 .dmg。
#
# 注:
#   - Sparkle 通过 SPM 装时,二进制不在 PATH;脚本会从 DerivedData 找。
#   - 找不到就 brew install sparkle 兜底(homebrew 版自带 generate_keys)。

set -euo pipefail
cd "$(dirname "$0")/../.."

# 1) 先试 DerivedData(SPM 拉下的 Sparkle.xcframework 自带 generate_keys)
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
CANDIDATE=$(find "$DERIVED" -name "generate_keys" -type f 2>/dev/null | head -1 || true)

# 2) 没找到就用 brew
if [[ -z "${CANDIDATE:-}" ]]; then
    if command -v generate_keys >/dev/null 2>&1; then
        CANDIDATE=$(command -v generate_keys)
    elif [[ -f "/opt/homebrew/Caskroom/sparkle/2.6.0/bin/generate_keys" ]]; then
        CANDIDATE="/opt/homebrew/Caskroom/sparkle/2.6.0/bin/generate_keys"
    else
        echo "ERROR: generate_keys not found." >&2
        echo "  install: brew install --cask sparkle" >&2
        echo "  or build Sparkle once via Xcode/SPM so DerivedData has the tool." >&2
        exit 1
    fi
fi

echo "Using: $CANDIDATE"
echo ""

# 已存在的 keypair 不会覆盖,Sparkle 自己处理。
"$CANDIDATE"

echo ""
echo "=================================================="
echo "Next steps:"
echo "  1. Copy the public key line above"
echo "  2. Open project.yml, replace PLACEHOLDER_RUN_generate-keys.sh"
echo "     in SUPublicEDKey with the public key"
echo "  3. Run: xcodegen generate"
echo "=================================================="
