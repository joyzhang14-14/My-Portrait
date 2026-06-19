#!/bin/bash
# sleephelper-verify.sh —— PortraitSleepHelper(特权 root daemon)端到端验证 + 排错。
#
# 打包了研究结论里的「first light」诊断:probe2 那种"helper 注册成功(enabled)但
# XPC 始终不通 / helper 没被 launchd 拉起"是静默失败 —— app 端连接只是干等超时,
# 没有崩溃报告也没有 XPC 错误。下面三招能立刻分清是哪一类:
#   · launchctl print system/<label>  → 有没有装进 system domain
#   · log stream <helper subsystem>   → helper 第一行 "helper launched" 有没有出现
#       没出现 = launchd 根本没启动它(签名/配置层);出现后很快没了 = helper 崩了
#   · pmset -g | grep SleepDisabled    → disablesleep 真实状态(1=钉醒,0=正常)
#
# 用法:
#   bash scripts/sleephelper-verify.sh status     # 一次性体检(建议 sudo 跑全)
#   bash scripts/sleephelper-verify.sh watch       # 实时看 helper 日志(开关 on/off 时跑)
#   bash scripts/sleephelper-verify.sh crashtest    # 崩溃安全:强杀 app 后 disablesleep 该回 0
set -uo pipefail

LABEL="com.joyzhang.myportrait.SleepHelper"
APPID="com.joyzhang.myportrait"

find_app() {
  for p in \
    "$HOME/Library/Developer/Xcode/DerivedData"/MyPortrait-*/Build/Products/Debug/MyPortrait.app \
    "$HOME/Library/Developer/Xcode/DerivedData"/MyPortrait-*/Build/Products/Release/MyPortrait.app \
    "/Applications/MyPortrait.app" "/Applications/My Portrait.app"; do
    [ -d "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

sleepdisabled() { pmset -g 2>/dev/null | grep -i SleepDisabled || echo "(无 SleepDisabled 行 → 当前 0/正常)"; }

status() {
  echo "━━━ PortraitSleepHelper 体检 ━━━"
  APP=$(find_app) || { echo "❌ 没找到 MyPortrait.app(先在 Xcode build & run 一次)"; exit 1; }
  echo "📦 app: $APP"
  HELPER="$APP/Contents/MacOS/PortraitSleepHelper"
  PLIST="$APP/Contents/Library/LaunchDaemons/$LABEL.plist"

  echo ""
  echo "1) bundle 内文件落位(SMAppService 要求都在 bundle 里):"
  [ -f "$HELPER" ] && echo "   ✅ helper 在 Contents/MacOS/PortraitSleepHelper" || echo "   ❌ 缺 $HELPER(BundleProgram 会指空 → 永不启动)"
  [ -f "$PLIST" ]  && echo "   ✅ daemon plist 在 Contents/Library/LaunchDaemons/" || echo "   ❌ 缺 $PLIST"
  if [ -f "$PLIST" ]; then
    echo "   BundleProgram = $(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST" 2>/dev/null)"
    echo "   MachServices  = $(/usr/libexec/PlistBuddy -c 'Print :MachServices' "$PLIST" 2>/dev/null | tr '\n' ' ')"
  fi

  echo ""
  echo "2) 签名 / 身份(helper 必须跟 app 同一 MyPortraitDev 叶证书,client 校验才过):"
  if [ -f "$HELPER" ]; then
    codesign -dr- "$HELPER" 2>&1 | grep -iE "designated|identifier|leaf" | sed 's/^/   helper /'
  fi
  codesign -dr- "$APP" 2>&1 | grep -iE "designated" | sed 's/^/   app    /'
  echo "   → helper main.swift 里钉的 client 要求应是 app 这行的 identifier + 同一 leaf=H\"...\""

  echo ""
  echo "3) launchd 是否装了这个 job(需 sudo 才看得全):"
  if launchctl print "system/$LABEL" >/tmp/_shp 2>/dev/null; then
    grep -iE "state =|program =|active count" /tmp/_shp | sed 's/^/   /'
  else
    echo "   (没装进 system domain,或没 sudo。开关打开 + 系统设置批准后才会在)"
    echo "   提示:sudo launchctl print system/$LABEL"
  fi
  rm -f /tmp/_shp

  echo ""
  echo "4) SMAppService 注册状态(从 app 内 General 开关看更准):"
  echo "   System Settings ▸ General ▸ Login Items & Extensions 里应有一项归在 MyPortrait 名下"

  echo ""
  echo "5) pmset 当前实际状态:"
  echo "   $(sleepdisabled)"
  echo ""
  echo "下一步:跑 watch 看实时日志,然后在 app 里开/关「合盖时保持运行」开关。"
}

watch() {
  echo "实时跟 helper 日志(subsystem=$LABEL)。现在去 app 里开关「合盖时保持运行」/ 触发后台任务。"
  echo "看到 'helper launched … reset-on-launch' = launchd 成功以 root 拉起了 helper ✅"
  echo "(Ctrl+C 退出)"
  sudo log stream --style compact --predicate "subsystem == \"$LABEL\"" --info --debug
}

crashtest() {
  echo "━━━ 崩溃安全验证:app 没了,disablesleep 必须自动回 0 ━━━"
  echo "前置:开关已开 + 已批准(.enabled)+ 有后台任务在跑 + 插电,使 disablesleep 已=1。"
  echo ""
  echo "当前 pmset:  $(sleepdisabled)"
  PID=$(pgrep -x MyPortrait | head -1)
  if [ -z "$PID" ]; then echo "（没找到运行中的 MyPortrait 进程，先 build & run 并让它进入 keep-awake 状态）"; exit 1; fi
  echo "MyPortrait pid=$PID"
  echo ""
  read -r -p "强杀 MyPortrait(kill -9 $PID)验证 helper 自动复位?[y/N] " yn
  [ "$yn" = "y" ] || { echo "已取消"; exit 0; }
  kill -9 "$PID"
  echo "已 kill。等 3s 让 helper 的 invalidationHandler 跑 pmset disablesleep 0 …"
  for i in 1 2 3; do sleep 1; printf '.'; done; echo
  echo "复位后 pmset: $(sleepdisabled)"
  echo "→ 应显示 0 / 无 SleepDisabled 行。若仍为 1 = 崩溃安全没生效,把上面 watch 的日志发我。"
}

morning() {
  HRS="${2:-12}"
  echo "━━━ 合盖一夜后体检(回看最近 ${HRS}h)━━━"
  echo ""
  echo "1) helper 自己的记录(.notice 级,持久;期望看到 helper launched / setKeepAwake(true) / last client gone):"
  log show --last "${HRS}h" --style compact \
      --predicate "subsystem == \"$LABEL\"" 2>/dev/null | tail -50 \
      || echo "   (查不到;若是合盖那晚之前的旧 build 仍 .info 级,记录不持久 —— 看 2/3 节)"
  echo ""
  echo "2) pmset 睡眠日志(铁证:任务时段机器有没有被 disablesleep 钉醒、没真睡):"
  pmset -g log 2>/dev/null | grep -iE "SleepDisabled|Entering Sleep|Wake from|DarkWake" | tail -40
  echo ""
  echo "3) 当前 pmset(任务跑完应回 0):"
  echo "   $(sleepdisabled)"
  echo ""
  echo "→ 另查:~/.portrait 下管线产物的 mtime 落在合盖时段 = 合盖时真干了活(最硬的证据)。"
}

case "${1:-status}" in
  status)    status ;;
  watch)     watch ;;
  crashtest) crashtest ;;
  morning)   morning "$@" ;;
  *) echo "用法: $0 status|watch|crashtest|morning [小时数]" ;;
esac
