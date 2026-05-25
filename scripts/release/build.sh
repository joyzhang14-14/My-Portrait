#!/usr/bin/env bash
# Archive + export 出可分发的 .app(Developer ID 签名)。
#
# 输出:
#   build/MyPortrait.xcarchive
#   build/export/MyPortrait.app
#
# 后续手动 / make notarize 拿这个 .app 提公证。

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

# 3) export
rm -rf "$EXPORT_DIR"
echo "→ xcodebuild exportArchive (developer-id)"
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

echo ""
echo "=================================================="
echo "Built: $APP_PATH"
echo ""
echo "Verify signing:"
echo "  codesign -dv --entitlements - $APP_PATH"
echo "  codesign --verify --deep --strict $APP_PATH"
echo "=================================================="
