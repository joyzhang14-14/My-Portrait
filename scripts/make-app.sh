#!/bin/bash
# Builds the Swift Package and wraps the binary into a proper macOS .app bundle.
#
# Why: `swift run` produces a bare executable that macOS treats as an
# accessory process. Wrapping in a .app bundle with Info.plist turns it
# into a first-class macOS app: Dock icon, reliable keyboard, window
# state persistence, etc.
#
# Usage:
#   ./scripts/make-app.sh                          (debug build)
#   ./scripts/make-app.sh release                  (release build)
#   ./scripts/make-app.sh && open MyPortrait.app   (build and launch)

set -e

CONFIG="${1:-debug}"
APP_NAME="MyPortrait"
DISPLAY_NAME="My Portrait"
BUNDLE_ID="com.joyzhang.MyPortrait"
APP_DIR="${APP_NAME}.app"

cd "$(dirname "$0")/.."

echo "Building Swift package ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH=".build/${CONFIG}/${APP_NAME}"
if [ ! -f "$BIN_PATH" ]; then
    echo "Binary not found at $BIN_PATH"
    exit 1
fi

echo "Creating $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
EOF

echo ""
echo "Built: $APP_DIR"
echo "Launch with:  open $APP_DIR"
