#!/bin/bash
# レポートを新しい順に一覧にする。1行の形は「ジョブ名 / 日付 / パス / 既読か」である。
# 使い方: list.sh [--unread]
#         list.sh --failures
#         list.sh --proposals
#   --unread    未読のものだけを出す
#   --proposals 承認待ち（status が pending）を「id / 見出し / targets」の形で id の昇順に出す
#   --failures  未読の失敗の知らせを「ジョブ名 / 日時 / パス」の形で出し、続けて ERROR の行を先頭3行まで字下げして出す
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib.sh"

unread_only=0
failures=0
proposals=0
for arg in "$@"; do
  case "$arg" in
    --unread) unread_only=1 ;;
    --failures) failures=1 ;;
    --proposals) proposals=1 ;;
    *) printf 'ERROR: 不明な引数です: %s\n' "$arg" >&2; exit 2 ;;
  esac
done
if [ $((failures + proposals + unread_only)) -gt 1 ]; then
  printf 'ERROR: --unread・--failures・--proposals は同時に指定できません\n' >&2
  exit 2
fi

if [ "$proposals" -eq 1 ]; then
  list_pending_proposals | while IFS="$TAB" read -r pid head targets; do
    printf '%s / %s / %s\n' "$pid" "$head" "$targets"
  done
  exit 0
fi

if [ "$failures" -eq 1 ]; then
  print_lines() {
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && printf '    %s\n' "$line"
    done <<<"$1"
  }
  for job in $FAIL_JOBS; do
    check_job_failure "$job" || continue
    if [ -n "$FAIL_LOG" ]; then
      scan_failure_file "$FAIL_LOG" log 0 "$MARK_TIME"
      printf '%s / %s / %s\n' "$job" "$SRC_TIME" "$FAIL_LOG"
      print_lines "$FAIL_LOG_LINES"
    fi
    if [ -n "$FAIL_STDERR" ]; then
      printf '%s / %s / %s\n' "$job" "$FAIL_TIME" "$FAIL_STDERR"
      print_lines "$FAIL_STDERR_LINES"
    fi
  done
  exit 0
fi

resolve_root || exit 0
if ! check_read_file; then
  printf 'ERROR: 既読の記録を読めません: %s\n' "$READ_FILE" >&2
  exit 1
fi

# 件数が多くても遅くならないよう、整形は awk で1回にまとめて行う。
list_reports_marked | LC_ALL=C sort -t "$TAB" -k1,1r -k2,2nr -k3,3 | awk -F '\t' -v unread_only="$unread_only" '
  $5 == "1" && unread_only == 1 { next }
  { print $3 " / " $1 " / " $4 " / " ($5 == "1" ? "既読" : "未読") }'
exit 0
