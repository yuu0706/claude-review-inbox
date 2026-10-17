#!/bin/bash
# Claude Code の SessionStart の hook から呼ばれる。今日の確認がまだなら、外部スキルの新しい版を確かめる。
# - repo-patrol と違い、結果をそのセッションの会話に出すため、裏へ切り離さずに同期で動かす。
#   全体は SKILL_UPDATES_DEADLINE 秒（既定 8）で打ち切る。
# - 標準出力には、新しい版があるときだけ check.py の JSON を出す。それ以外は何も出さない。
# - 確認できなかったとき（ネットワークの失敗など）は何も出さず、ログに1行残す。
#   失敗の後 RETRY_MIN 分は確かめ直さない（つながらない環境でセッションのたびに待たせないため）。
# - 今日の確認が済んでいれば、ネットワークに触れずにすぐ終わる。
# bash 3.2（macOS 標準）で動くように書く。
set -u
exec 3>&1 >/dev/null 2>&1

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 0
PYTHON="${CLAUDE_REVIEW_PYTHON:-/usr/bin/python3}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
export SKILL_UPDATES_STATE="${SKILL_UPDATES_STATE:-${STATE_BASE%/}/skill-updates}"
STATE_DIR="$SKILL_UPDATES_STATE"
TODAY="${SKILL_UPDATES_TODAY:-$(date '+%Y-%m-%d')}"
export SKILL_UPDATES_TODAY="$TODAY"
CHECKED="$STATE_DIR/last-checked"
FAILED="$STATE_DIR/last-failed"
LOCK="$STATE_DIR/lock"
LOG="$STATE_DIR/check.log"
RETRY_MIN="${SKILL_UPDATES_RETRY_MIN:-60}"
LOCK_STALE_MIN=10
LOCK_FILE="${SKILL_UPDATES_LOCK:-$HOME/skills-lock.json}"

[ -f "$LOCK_FILE" ] || exit 0
[ "$(cat "$CHECKED" 2>/dev/null)" = "$TODAY" ] && exit 0
if [ -f "$FAILED" ] && [ -z "$(find "$FAILED" -mmin +"$RETRY_MIN" 2>/dev/null)" ]; then
  exit 0
fi
[ -x "$PYTHON" ] || exit 0
mkdir -p "$STATE_DIR" || exit 0

if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null
fi
# 同時に始まった別のセッションが確かめている。知らせはそちらに出る。
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

out="$(mktemp "$STATE_DIR/out.XXXXXX")" || exit 0
err="$(mktemp "$STATE_DIR/err.XXXXXX")" || exit 0
if "$PYTHON" -B -I "$SCRIPT_DIR/check.py" >"$out" 2>"$err"; then
  printf '%s\n' "$TODAY" >"$CHECKED"
  rm -f "$FAILED"
  printf '[%s] OK\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG"
  cat "$out" >&3
else
  : >"$FAILED"
  printf '[%s] FAIL: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(head -n 1 "$err" | tr -d '\r')" >>"$LOG"
fi
rm -f "$out" "$err"
exit 0
