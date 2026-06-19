#!/bin/bash
# smappservice-probe.sh — 验证【自签证书】能不能注册 SMAppService root daemon。
#
# 命门:My-Portrait 本地走自签 cert(MyPortraitDev),不是 Apple Developer ID。
# SMAppService 注册 root daemon 对签名很挑,自签能不能成有不确定性。本脚本组一个
# 最小签名 .app(含空壳 helper + daemon plist),调 register() 看 .status,然后
# unregister() 清理。register OK / requiresApproval = 自签可行;FAILED = 不行。
#
# 用法:  bash scripts/smappservice-probe.sh [签名身份名或SHA]
#   不传参数会自动找 keychain 里含 "MyPortrait" 的 codesigning 身份。
set -uo pipefail

IDENTITY="${1:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -iE "MyPortrait" | head -1 | sed -E 's/.*"(.*)"/\1/')
fi
if [ -z "$IDENTITY" ]; then
  echo "❌ 没找到含 MyPortrait 的签名身份。下面是你所有 codesigning 身份,挑一个重跑:"
  echo "   bash scripts/smappservice-probe.sh \"<身份名>\""
  security find-identity -v -p codesigning
  exit 1
fi
echo "🔑 签名身份: $IDENTITY"

BUILD=$(mktemp -d)
APP="$BUILD/SMTest.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
LABEL="com.joyzhang.myportrait.smtest"

# ---- app 源:调 register() 打印 status ----
cat > "$BUILD/app.swift" <<'SWIFT'
import Foundation
import ServiceManagement
func name(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered:   return "notRegistered"
    case .enabled:         return "enabled ✅"
    case .requiresApproval:return "requiresApproval ✅(可行,去 System Settings 开即可)"
    case .notFound:        return "notFound"
    @unknown default:      return "unknown(\(s.rawValue))"
    }
}
let svc = SMAppService.daemon(plistName: "com.joyzhang.myportrait.smtest.plist")
print("[probe] status before:", name(svc.status))
do {
    try svc.register()
    print("[probe] register() OK ✅")
} catch {
    let e = error as NSError
    print("[probe] register() FAILED ❌:", e.localizedDescription, "[", e.domain, e.code, "]")
}
print("[probe] status after:", name(svc.status))
try? svc.unregister()
print("[probe] cleanup: unregister done")
SWIFT

# ---- helper 源:空壳常驻(注册测试不真跑它,只需存在且签名)----
echo 'import Foundation; RunLoop.main.run()' > "$BUILD/helper.swift"

# ---- helper 内嵌 Info.plist(CFBundleIdentifier 必须有)----
cat > "$BUILD/helper-info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$LABEL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# ---- daemon plist(嵌进 bundle)----
cat > "$APP/Contents/Library/LaunchDaemons/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>BundleProgram</key><string>Contents/MacOS/smtest-helper</string>
<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
<key>AssociatedBundleIdentifiers</key><array><string>com.joyzhang.myportrait.smtestapp</string></array>
</dict></plist>
PLIST

# ---- app Info.plist ----
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.joyzhang.myportrait.smtestapp</string>
<key>CFBundleExecutable</key><string>SMTest</string>
<key>CFBundleName</key><string>SMTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST

echo "🔨 编译…"
swiftc "$BUILD/app.swift" -o "$APP/Contents/MacOS/SMTest" || { echo "app 编译失败"; exit 1; }
swiftc "$BUILD/helper.swift" -o "$APP/Contents/MacOS/smtest-helper" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$BUILD/helper-info.plist" \
    || { echo "helper 编译失败"; exit 1; }

echo "✍️  签名(先 helper 再 app)…"
codesign --force --options runtime --sign "$IDENTITY" --identifier "$LABEL" "$APP/Contents/MacOS/smtest-helper" || exit 1
codesign --force --options runtime --sign "$IDENTITY" --identifier com.joyzhang.myportrait.smtestapp "$APP" || exit 1
echo "验签:"; codesign -dv "$APP" 2>&1 | grep -iE "Authority|Identifier" | head -3

echo ""
echo "===== 运行 register() 探测 ====="
"$APP/Contents/MacOS/SMTest"
echo "==============================="
echo ""
echo "解读:register() OK 或 status=enabled/requiresApproval → ✅ 自签可行,daemon 路线能走。"
echo "      register() FAILED(尤其 'Operation not permitted'/code 1)→ ❌ 自签注册不了 root daemon。"
echo "bundle 留在(排查用,可删): $APP"
