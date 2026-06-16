#!/bin/bash
# lidrun — 合盖【满速】跑任意命令(Apple Silicon + 插电)。
#
# 背景(经实测取证):合盖(clamshell)睡眠走 macOS 的 IOPMrootDomain 独立路径,
# 普通的 caffeinate / IOPMAssertion 断言挡不住它 —— 合盖后机器进 Sleep⇄DarkWake
# 循环,任务虽能在 DarkWake 窗口里机会性继续推进,但占空被节流、慢约 3 倍。
# 要合盖【满速】跑,唯一的纯软件办法是 `pmset -c disablesleep 1`(需 sudo)。
#
# 本脚本做的事:
#   1. 跑前 `sudo pmset -c disablesleep 1`(AC 档禁合盖睡眠)+ 起一个 `caffeinate -s`
#      兜底(万一 pmset 被别的进程改回)。
#   2. 后台 keepalive 每 50s 刷新 sudo 时间戳 —— 保证无人值守跑一整晚后,
#      结束时的恢复命令也不会因 sudo 过期而失败。
#   3. 跑完(含正常结束 / Ctrl-C / 报错 / 被 kill)自动把 disablesleep 恢复到
#      原值、释放 caffeinate,并透传被包命令的退出码。
#
# 用法:
#   scripts/lidrun.sh <command> [args...]
# 例:
#   scripts/lidrun.sh python3 Tests/event-local-lab/run_day.py 2026-06-07
#   scripts/lidrun.sh make eval
# 建议软链到 PATH 当作 `lidrun` 用:
#   ln -s "$PWD/scripts/lidrun.sh" /usr/local/bin/lidrun
#
# 注意:① 只在【插电】下有意义(电池下合盖一定睡,disablesleep -c 是 AC 档)。
#       ② 合盖散热差,长时间满载有过热风险。
#       ③ 需要 sudo,仅用于 pmset。

set -uo pipefail

log() { printf '\033[36m[lidrun]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[lidrun]\033[0m %s\n' "$*" >&2; }

if [ "$#" -eq 0 ]; then
  err "用法: $(basename "$0") <command> [args...]"
  exit 64
fi

# —— 插电检查(只警告,不阻止;用户可能马上插上)——
if ! pmset -g batt 2>/dev/null | head -1 | grep -q "AC Power"; then
  err "⚠️  当前不是 AC 供电 —— 电池下合盖仍会睡。请插上电源再合盖。"
fi

# —— 提权:先 prime 一次 sudo,再起后台 keepalive 刷新时间戳 ——
if ! sudo -v; then
  err "需要 sudo 来执行 pmset(仅此用途)。已退出。"
  exit 77
fi
( while true; do sudo -n true 2>/dev/null || exit; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE_PID=$!

# —— 记录原始 disablesleep 值,退出时恢复到原值(而非粗暴置 0)——
ORIG="$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2}')"
ORIG="${ORIG:-0}"

CAFFEINATE_PID=""

cleanup() {
  trap - EXIT INT TERM
  log "恢复中…"
  sudo -n pmset -c disablesleep "$ORIG" 2>/dev/null \
    || sudo pmset -c disablesleep "$ORIG" 2>/dev/null \
    || err "⚠️ 恢复 disablesleep 失败,请手动执行: sudo pmset -c disablesleep 0"
  [ -n "$CAFFEINATE_PID" ] && kill "$CAFFEINATE_PID" 2>/dev/null
  [ -n "${KEEPALIVE_PID:-}" ] && kill "$KEEPALIVE_PID" 2>/dev/null
  log "已恢复:disablesleep=$ORIG,caffeinate 已释放。"
}
# EXIT 兜底总恢复;INT/TERM 转成 exit → 触发 EXIT trap,确保被 kill 也能恢复。
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# —— 启用合盖满速 ——
log "启用合盖满速:pmset -c disablesleep 1 + caffeinate -s 兜底"
if ! sudo pmset -c disablesleep 1; then
  err "⚠️ 设置 disablesleep 失败,合盖可能仍会被节流(降级为 DarkWake 模式)。"
fi
caffeinate -s &
CAFFEINATE_PID=$!

# —— 跑命令,透传退出码 ——
log "▶ 跑:$*"
"$@"
RC=$?
log "◀ 完成,退出码 $RC"
exit "$RC"
