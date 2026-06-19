#!/bin/bash
# sleephelper-xpc-test.sh —— 不靠 app 数据,直接验 PortraitSleepHelper 的 XPC 全链路:
#   ① on-demand 被 launchd 拉起  ② 调用方签名校验通过  ③ pmset disablesleep 翻转
#   ④ 崩溃安全:客户端不复位直接退出,helper 应自动把 disablesleep 复位 0。
#
# 原理:helper 只认 `identifier "com.joyzhang.myportrait" + MyPortraitDev 叶证书` 的
# 调用方。这里编一个最小 XPC 客户端,用 codesign --identifier com.joyzhang.myportrait
# --sign MyPortraitDev 签 → 满足要求 → 连得上(攻击者没 MyPortraitDev 私钥伪造不了,
# 所以不是漏洞,只是本机自测,等价 app 那条连接路径)。
#
# 全唤醒(开盖)下跑,确认 helper 机制本身通。helper 不看电源(门槛在 app 里),
# 电池上也能测。结尾保证 disablesleep 回 0。
#
# 前置:General ▸「合盖时保持运行」已开 + 系统设置已批准(status=enabled)。
# 用法:  bash scripts/sleephelper-xpc-test.sh
set -uo pipefail
LABEL="com.joyzhang.myportrait.SleepHelper"
APPID="com.joyzhang.myportrait"
ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "MyPortraitDev" | head -1 | sed -E 's/.*"(.*)"/\1/')
[ -z "$ID" ] && { echo "❌ 找不到 MyPortraitDev 签名身份"; exit 1; }

DIR=$(mktemp -d)
SRC="$DIR/client.swift"
BIN="$DIR/shpxpc"

cat > "$SRC" <<'SWIFT'
import Foundation

// 必须跟 helper 的 @objc(PortraitSleepHelperProtocol) 逐字一致。
@objc(PortraitSleepHelperProtocol) protocol PortraitSleepHelperProtocol {
    func setKeepAwake(_ enabled: Bool, withReply reply: @escaping (Bool, String) -> Void)
    func ping(withReply reply: @escaping (String) -> Void)
}

func sleepDisabled() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g"]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run(); p.waitUntilExit() } catch { return "?" }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").first { $0.localizedCaseInsensitiveContains("SleepDisabled") }
        .map { $0.trimmingCharacters(in: .whitespaces) } ?? "(无 SleepDisabled 行 = 0)"
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "check"
let c = NSXPCConnection(machServiceName: "com.joyzhang.myportrait.SleepHelper", options: .privileged)
c.remoteObjectInterface = NSXPCInterface(with: PortraitSleepHelperProtocol.self)
c.invalidationHandler = {
    FileHandle.standardError.write(Data("  [client] XPC invalidated —— helper 没被拉起 / 被签名校验拒了?\n".utf8))
}
c.resume()
guard let proxy = c.remoteObjectProxyWithErrorHandler({ e in
    FileHandle.standardError.write(Data("  [client] XPC ERROR ❌: \(e.localizedDescription)\n".utf8))
}) as? PortraitSleepHelperProtocol else { print("no proxy"); exit(2) }

let sem = DispatchSemaphore(value: 0)

if mode == "reset" {   // 安全复位用
    proxy.setKeepAwake(false) { _, _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 8); exit(0)
}

print("① ping —— 确认 helper 被 launchd 以 root 拉起:")
proxy.ping { r in print("   →", r); sem.signal() }
if sem.wait(timeout: .now() + 8) == .timedOut { print("   ❌ 8s 无回复(见上面 XPC ERROR / invalidated)"); exit(3) }

print("② setKeepAwake(true):")
proxy.setKeepAwake(true) { ok, diag in print("   → ok=\(ok) \(diag)"); sem.signal() }
_ = sem.wait(timeout: .now() + 8)
print("   pmset:", sleepDisabled(), "(期望 1)")

if mode == "leak" {
    print("③ [模拟崩溃] 不调 false 直接退出 → helper 应自动复位 0")
    exit(0)
}

print("③ setKeepAwake(false):")
proxy.setKeepAwake(false) { ok, diag in print("   → ok=\(ok) \(diag)"); sem.signal() }
_ = sem.wait(timeout: .now() + 8)
print("   pmset:", sleepDisabled(), "(期望 0)")
exit(0)
SWIFT

echo "🔨 编译 + 签名(identifier=$APPID, cert=MyPortraitDev)…"
swiftc "$SRC" -o "$BIN" || { echo "编译失败"; exit 1; }
codesign --force --options runtime --identifier "$APPID" --sign "$ID" "$BIN" || { echo "签名失败"; exit 1; }
codesign -dr- "$BIN" 2>&1 | grep -i designated | sed 's/^/   验签: /'

echo ""
echo "━━━ A. 全链路(ping → set1 → 验 → set0 → 验)━━━"
"$BIN" check

echo ""
echo "等 3s 让 A 的 helper 完全退出,避免 B 撞上正在退出的实例 …"; sleep 3
echo "━━━ B. 崩溃安全(set1 后强退,helper 该自动复位)━━━"
"$BIN" leak
echo "   等 3s 让 helper invalidationHandler 跑 pmset 0 …"; sleep 3
LEFT=$(pmset -g | grep -i SleepDisabled || true)
echo "   复位后 pmset: ${LEFT:-（无 SleepDisabled 行 = 0 ✅）}"

# 安全兜底:不管怎样结尾确保 disablesleep=0
if echo "$LEFT" | grep -q "1"; then
  echo "   ⚠️ 仍为 1,强制复位…"; "$BIN" reset; sleep 1
  pmset -g | grep -i SleepDisabled || echo "   已复位 0 ✅"
fi

rm -rf "$DIR"
echo ""
echo "判读:A 出现 helper uid=0 + pmset 在 1↔0 间翻 = 全链路通 ✅(那昨晚没起=DarkWake 拉起限制)。"
echo "      出现 XPC ERROR / 8s 无回复 = 连全唤醒都连不上,是 XPC/签名问题,把上面报错发我。"
