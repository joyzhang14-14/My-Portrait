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
SIGN_IDENTITY="${CODESIGN_IDENTITY:-MyPortraitDev}"

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

    <!-- TCC usage strings: explain WHY we touch the privacy-protected folders.
         macOS shows these in the consent prompt. They also make the grant
         "stickier" because the system records the purpose alongside the
         allow-list entry. -->
    <key>NSDocumentsFolderUsageDescription</key>
    <string>My Portrait's AI agent reads files from your Documents folder when you ask it to.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>My Portrait's AI agent reads files from your Desktop when you ask it to.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>My Portrait's AI agent reads files from your Downloads folder when you ask it to.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>My Portrait controls helper processes (Bun + Pi agent) to talk to ChatGPT.</string>

    <!-- Capture layer permissions (P1-P4). All keep data local on disk. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>My Portrait listens to your microphone, segments it locally, and transcribes the audio on-device. Audio stays on this Mac.</string>
</dict>
</plist>
EOF

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    # Custom designated requirement: identify the app by its bundle id +
    # signing certificate's Common Name only — NOT by the binary's cdhash.
    # TCC (Documents/Desktop/Downloads), Firewall, and Keychain all use this
    # requirement to decide "is this the same app as before?". Tying it to
    # the cert CN means every rebuild signed with $SIGN_IDENTITY is the
    # SAME app from the OS's perspective, so the user only grants access
    # once and the grant survives all future rebuilds.
    REQ='designated => identifier "'"$BUNDLE_ID"'" and anchor trusted and certificate leaf[subject.CN] = "'"$SIGN_IDENTITY"'"'

    echo "Signing with $SIGN_IDENTITY (stable designated requirement)..."
    codesign --force --deep \
        --sign "$SIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" \
        --requirements "=$REQ" \
        "$APP_DIR"
    codesign --verify --verbose "$APP_DIR"
else
    echo "Skip signing: identity '$SIGN_IDENTITY' not found in keychain."
fi

echo ""
echo "Built: $APP_DIR"
echo "Launch with:  open $APP_DIR"
