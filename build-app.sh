#!/bin/bash
# 把 SwiftPM 裸可执行文件包成签名的 MyPortrait.app。
#
# 为什么需要：SwiftPM 项目 `xcodebuild` 产出的是裸 Mach-O 可执行文件，不是
# .app bundle。macOS TCC（屏幕录制 / 麦克风权限）对裸文件按 cdhash 匹配 ——
# 每次 rebuild cdhash 都变，授权立刻失效。
#
# 包成 .app + 用固定证书（MyPortraitDev）签名后，TCC 改按"designated
# requirement"（证书链）匹配，跨 rebuild 稳定 —— 授权一次永久有效。
#
# 用法：./build-app.sh [--run]
#   --run  打包完直接启动 MyPortrait.app
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="MyPortrait"
DERIVED="/tmp/mp-xc"
BUILD_DIR="$DERIVED/Build/Products/Debug"
APP="build/MyPortrait.app"
BUNDLE_ID="com.joyzhang.myportrait"
SIGN_IDENTITY="MyPortraitDev"

echo "==> xcodebuild ($SCHEME)"
xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" build 2>&1 | tail -3

if [ ! -f "$BUILD_DIR/MyPortrait" ]; then
    echo "ERROR: binary not found at $BUILD_DIR/MyPortrait"
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# 1) 主可执行文件
cp "$BUILD_DIR/MyPortrait" "$APP/Contents/MacOS/MyPortrait"

# 2) SPM 资源 bundle → Contents/Resources/。
#    .app 里 SPM 的 Bundle.module 查 Bundle.main.resourceURL（= Contents/Resources/），
#    **不查** Contents/MacOS/。裸 binary 能用是因为 resourceURL 就是 exe 同级目录。
#    mlx-swift_Cmlx.bundle 里有 default.metallib，MLX 推理离了它就崩。
for b in "$BUILD_DIR"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/Resources/"
done

# 3) Info.plist —— 有了它进程才算"跑在 .app bundle 里"，bundle identifier 才非空。
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MyPortrait</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>MyPortrait</string>
    <key>CFBundleDisplayName</key>
    <string>My Portrait</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>My Portrait records microphone audio to build your personal activity timeline.</string>
    <key>NSCameraUsageDescription</key>
    <string>My Portrait does not use the camera.</string>
</dict>
</plist>
PLIST

# 4) 签名 —— 固定证书 + 固定 bundle id。
#    bundle 在 Contents/Resources/ 里只是资源，codesign 会随 .app 一起密封，
#    不用单独签。直接签 .app 本体即可。
#    不上 hardened runtime（dev build；省去 entitlement 配置）。
echo "==> codesign ($SIGN_IDENTITY) app"
codesign --force --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --timestamp=none \
    "$APP" 2>&1

echo "==> codesign verify"
codesign --verify --verbose=2 "$APP" 2>&1 || true

echo ""
echo "built: $APP"
echo "bundle id: $BUNDLE_ID  signed: $SIGN_IDENTITY"

if [ "${1:-}" = "--run" ]; then
    echo "==> launching"
    open "$APP"
fi
