#!/bin/bash
# Claude Code の SessionStart フックから呼ばれ、前回の起動から一定の日数がたっていれば patrol.sh を裏で1回起動する。
# フックとして、標準出力に何も出さず、すぐに終了コード 0 で終わる。失敗しても会話の開始を妨げない。
# 環境変数:
#   SECRET_PATROL_INTERVAL_DAYS  起動の間隔（日）。既定 7
#   SECRET_PATROL_SCRIPT         起動するスクリプト。既定はこのスクリプトと同じディレクトリの patrol.sh
#   CLAUDE_REPORTS_STATE         状態の置き場所。patrol.sh と同じ
#   SECRET_PATROL_HOME           一覧できるかを確かめる Documents・Downloads・Desktop の親。既定 $HOME
# bash 3.2（macOS 標準）で動くように書く。
set -u

exec >/dev/null 2>&1

# フックの JSON は使わない。読み終わりを待たないよう、裏で読み捨てる。
if [ ! -t 0 ]; then
  # 裏の処理の標準入力は既定で /dev/null になるため、明示して引き継ぐ。
  cat <&0 >/dev/null 2>&1 &
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || exit 0
PATROL="${SECRET_PATROL_SCRIPT:-$SCRIPT_DIR/patrol.sh}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
STATE_DIR="${STATE_BASE%/}/secret-patrol"
LAST_FILE="$STATE_DIR/last-trigger"

interval_days="${SECRET_PATROL_INTERVAL_DAYS:-7}"
case "$interval_days" in
  ''|*[!0-9]*) interval_days=7 ;;
esac

mkdir -p "$STATE_DIR" || exit 0

# 実行中であれば起動しない。
[ -e "$STATE_DIR/lock" ] && exit 0

now="$(date +%s)"
last=""
[ -f "$LAST_FILE" ] && last="$(head -n 1 "$LAST_FILE" 2>/dev/null | tr -d ' \t\r\n')"
case "$last" in
  ''|*[!0-9]*) last=0 ;;
esac
[ $((now - last)) -ge $((interval_days * 86400)) ] || exit 0

[ -f "$PATROL" ] || exit 0

# 見回りの対象を一覧できなければ起動しない。launchd から起動された claude -p では TCC により読めず、
# 失敗した見回りで起動の権利を使ってしまうためである。存在しないフォルダは確かめない。
# 対象は設定ファイル（patrol.sh と同じ）で決まる。書類・デスクトップ・ダウンロードは PERSONAL_FOLDERS が yes のときだけ確かめ、
# 見回らないフォルダを ls して macOS の許可のダイアログを出さない。
TARGET_HOME="${SECRET_PATROL_HOME:-$HOME}"
PATROL_CONF="${CLAUDE_REVIEW_PATROL_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/patrol.conf}"
personal="no"
roots=""
if [ -f "$PATROL_CONF" ]; then
  personal="$(sed -n 's/^PERSONAL_FOLDERS=//p' "$PATROL_CONF" | tail -n 1)"
  roots="$(sed -n 's/^REPO_ROOTS=//p' "$PATROL_CONF" | tail -n 1)"
fi
if [ "$personal" = "yes" ]; then
  for d in Documents Downloads Desktop; do
    [ -e "$TARGET_HOME/$d" ] || continue
    ls "$TARGET_HOME/$d" >/dev/null 2>&1 || exit 0
  done
fi
while IFS= read -r d; do
  case "$d" in "~/"*) d="$HOME/${d#\~/}" ;; esac
  [ -n "$d" ] && [ -e "$d" ] || continue
  ls "$d" >/dev/null 2>&1 || exit 0
done < <(printf '%s\n' "$roots" | tr ':' '\n')

# 時刻を書けなければ起動しない。書けないまま起動すると、会話を始めるたびに起動するためである。
printf '%s\n' "$now" >"$LAST_FILE" || exit 0

# フックの終了を待たせないよう、切り離して起動する。出力は patrol.sh 自身がログへ書く。
( nohup /bin/bash "$PATROL" </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
disown -a 2>/dev/null
exit 0
