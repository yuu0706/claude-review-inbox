#!/bin/bash
# Claude Code の SessionStart の hook から呼ばれる。今日の結果がまだ無ければ patrol.sh を裏で1回だけ動かす。
# - 標準出力と標準エラーには何も出さない（SessionStart の hook の出力は会話に入るため）。
# - 対象のフォルダを一覧できなければ何もせずに終了コード0で終える。結果もログも書かず、次のセッションに持ち越す。
#   launchd から起動した claude -p でもこの hook が走り、TCC により ~/Documents を読めないためである。
# - 同時に複数のセッションが始まっても1回だけ動くよう、mkdir のロックで排他する。
# - patrol.sh は切り離して動かし、このスクリプトはすぐに戻る。
# bash 3.2（macOS 標準）で動くように書く。
set -u
exec >/dev/null 2>&1

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 0
JOB_NAME="repo-patrol"
# 巡回の対象の決め方は patrol.sh と同じ。対象が無ければ、フォルダを一覧せずに何もしない。
PATROL_CONF="${CLAUDE_REVIEW_PATROL_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/patrol.conf}"
if [ -n "${REPO_PATROL_ROOT:-}" ]; then
  PATROL_ROOT="$REPO_PATROL_ROOT"
elif [ -f "$PATROL_CONF" ]; then
  PATROL_ROOT="$(sed -n 's/^REPO_ROOTS=//p' "$PATROL_CONF" | tail -n 1)"
  PATROL_ROOT="${PATROL_ROOT%%:*}"
  case "$PATROL_ROOT" in "~/"*) PATROL_ROOT="$HOME/${PATROL_ROOT#\~/}" ;; esac
else
  PATROL_ROOT=""
fi
PATROL_ROOT="${PATROL_ROOT%/}"
[ -n "$PATROL_ROOT" ] || exit 0
REPORTS_ROOT="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORTS_ROOT="${REPORTS_ROOT%/}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
STATE_DIR="${STATE_BASE%/}/$JOB_NAME"
# patrol.sh 自身の lock とは別に、起動の排他に使う lock。
TRIGGER_LOCK="$STATE_DIR/trigger.lock"
# この分数より古い起動の lock は、強制終了などで残ったものとみなして外す。
LOCK_STALE_MIN=120

# 今日の結果がまだ無ければ 0 を返す。
is_due() {
  [ ! -e "$REPORTS_ROOT/$JOB_NAME/$(date '+%Y-%m-%d').md" ]
}

is_due || exit 0

# 読めなかったので見送ったことを1行だけ残す。日時と理由だけを書く。
note_skipped() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '[%s] SKIP: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$STATE_DIR/skipped.log" 2>/dev/null
}

if ! ls "$PATROL_ROOT" >/dev/null 2>&1; then
  note_skipped "対象のフォルダを一覧できないため見送った: ${PATROL_ROOT}"
  exit 0
fi

mkdir -p "$STATE_DIR" || exit 0

# 古い起動の lock を外す。
if [ -d "$TRIGGER_LOCK" ] && [ -n "$(find "$TRIGGER_LOCK" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
  rmdir "$TRIGGER_LOCK" 2>/dev/null
fi
mkdir "$TRIGGER_LOCK" 2>/dev/null || exit 0

# lock を取った後に、もう一度確かめる。別のセッションが直前に終えている場合がある。
# patrol.sh が手動などで実行中のときも動かさない（二重起動の ERROR をログに出さないため）。
if ! is_due || [ -d "$STATE_DIR/lock" ]; then
  rmdir "$TRIGGER_LOCK" 2>/dev/null
  exit 0
fi

# patrol.sh を切り離して動かし、終わったら起動の lock を外す。
nohup /bin/bash -c '"$1"; rmdir "$2" 2>/dev/null' run-if-due "$SCRIPT_DIR/patrol.sh" "$TRIGGER_LOCK" \
  </dev/null >/dev/null 2>&1 &
exit 0
