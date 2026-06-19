#!/bin/bash
# smappservice-probe2.sh — 端到端验证:自签 daemon 批准后能否 enabled + XPC 连通 + helper 以 root 跑 pmset。
# 分三步:
#   bash scripts/smappservice-probe2.sh build   # 建+签+注册;然后去 System Settings 批准
#   bash scripts/smappservice-probe2.sh test     # 批准后跑:XPC 连 helper,让它以 root 验 pmset
#   bash scripts/smappservice-probe2.sh clean     # 注销 + 删 bundle
set -uo pipefail
CMD="${1:-}"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "MyPortraitDev" | head -1 | sed -E 's/.*"(.*)"/\1/')
LABEL="com.joyzhang.myportrait.smtest"
APPID="com.joyzhang.myportrait.smtestapp"
ROOT="$HOME/.portrait/smtest"
APP="$ROOT/SMTest.app"
BIN="$APP/Contents/MacOS/SMTest"

build() {
  [ -z "$IDENTITY" ] && { echo "❌ 无 MyPortraitDev 身份"; exit 1; }
  rm -rf "$ROOT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
  # app(单文件编译,top-level 允许;proto 内联)
  cat > "$ROOT/app.swift" <<S
import Foundation
import ServiceManagement
@objc(Diag) protocol Diag { func diagnose(withReply reply: @escaping (String) -> Void) }
let svc = SMAppService.daemon(plistName: "$LABEL.plist")
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
func sname(_ s: SMAppService.Status) -> String { ["notRegistered","enabled ✅","requiresApproval(去Settings开)","notFound"][safe: Int(s.rawValue)] ?? "?" }
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
if mode == "register" {
  print("[app] status:", sname(svc.status))
  do { try svc.register(); print("[app] register OK") } catch { print("[app] register threw:", (error as NSError).code, "(首次 requiresApproval 正常)") }
  print("[app] status now:", sname(svc.status))
  print("[app] 去 System Settings ▸ General ▸ Login Items & Extensions ▸ Allow in the Background 把它打开,再跑 test")
} else if mode == "test" {
  print("[app] status:", sname(svc.status))
  let c = NSXPCConnection(machServiceName: "$LABEL", options: .privileged)
  c.remoteObjectInterface = NSXPCInterface(with: Diag.self)
  c.resume()
  let sem = DispatchSemaphore(value: 0)
  let proxy = c.remoteObjectProxyWithErrorHandler { e in print("[app] XPC ERROR ❌:", e.localizedDescription); sem.signal() } as? Diag
  proxy?.diagnose { reply in print("[app] helper 回复:\n" + reply); sem.signal() }
  _ = sem.wait(timeout: .now() + 8)
} else if mode == "unregister" {
  try? svc.unregister(); print("[app] unregistered")
}
S
  # helper
  cat > "$ROOT/helper.swift" <<'S'
import Foundation
@objc(Diag) protocol Diag { func diagnose(withReply reply: @escaping (String) -> Void) }
final class DiagImpl: NSObject, Diag {
  func diagnose(withReply reply: @escaping (String) -> Void) {
    func sh(_ a: [String]) -> String { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = a; let pi = Pipe(); p.standardOutput = pi; p.standardError = pi; try? p.run(); p.waitUntilExit(); return String(data: pi.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
    var m = "uid=\(getuid()) (0=root ✅)\n"
    if getuid() == 0 {
      _ = sh(["-c","disablesleep","1"]); let chk = sh(["-g"]).split(separator: "\n").first { $0.localizedCaseInsensitiveContains("SleepDisabled") }.map(String.init) ?? "(无 SleepDisabled 行)"; _ = sh(["-c","disablesleep","0"])
      m += "pmset set1: \(chk)\n→ root 跑 pmset disablesleep 成功 ✅(已复位 0)"
    } else { m += "非 root,跑不了 pmset ❌" }
    reply(m)
  }
}
final class Del: NSObject, NSXPCListenerDelegate {
  func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
    c.exportedInterface = NSXPCInterface(with: Diag.self); c.exportedObject = DiagImpl(); c.resume(); return true
  }
}
let l = NSXPCListener(machServiceName: "com.joyzhang.myportrait.smtest")
let d = Del(); l.delegate = d; l.resume(); RunLoop.main.run()
S
  cat > "$ROOT/hinfo.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$LABEL</string><key>CFBundleInfoDictionaryVersion</key><string>6.0</string></dict></plist>
P
  cat > "$APP/Contents/Library/LaunchDaemons/$LABEL.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>$LABEL</string><key>BundleProgram</key><string>Contents/MacOS/smtest-helper</string><key>MachServices</key><dict><key>$LABEL</key><true/></dict><key>AssociatedBundleIdentifiers</key><array><string>$APPID</string></array></dict></plist>
P
  cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$APPID</string><key>CFBundleExecutable</key><string>SMTest</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSMinimumSystemVersion</key><string>13.0</string></dict></plist>
P
  echo "🔨 编译…"
  swiftc "$ROOT/app.swift" -o "$BIN" || exit 1
  swiftc "$ROOT/helper.swift" -o "$APP/Contents/MacOS/smtest-helper" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/hinfo.plist" || exit 1
  echo "✍️  签名…"
  codesign --force --options runtime --sign "$IDENTITY" --identifier "$LABEL" "$APP/Contents/MacOS/smtest-helper" || exit 1
  codesign --force --options runtime --sign "$IDENTITY" --identifier "$APPID" "$APP" || exit 1
  echo "🚀 注册…"; "$BIN" register
  echo ""; echo "👉 现在去 System Settings ▸ General ▸ Login Items & Extensions ▸ 把 'SMTest'(或 com.joyzhang.myportrait)打开,然后跑: bash scripts/smappservice-probe2.sh test"
}

case "$CMD" in
  build) build ;;
  test)  [ -x "$BIN" ] && "$BIN" test || echo "先跑 build";;
  clean) [ -x "$BIN" ] && "$BIN" unregister; rm -rf "$ROOT"; echo "已清理";;
  *) echo "用法: $0 build|test|clean";;
esac
