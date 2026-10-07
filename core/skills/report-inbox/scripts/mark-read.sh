#!/bin/bash
# レポートと定期実行の失敗の知らせを既読にする。
# レポートは既読の記録（read.txt）へパスを1行ずつ足す。失敗の知らせはジョブごとに既読にした時刻を記録する。
# 使い方: mark-read.sh <レポートのパス...>
#         mark-read.sh --all                 現在あるレポートと、全ジョブの失敗の知らせを既読にする
#         mark-read.sh --failures            全ジョブの失敗の知らせを既読にする
#         mark-read.sh --failure <ジョブ名>   指定したジョブの失敗の知らせを既読にする
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib.sh"

usage() {
  printf '使い方: %s <レポートのパス...> | --all | --failures | --failure <ジョブ名>\n' "${0##*/}" >&2
}

# 失敗の知らせを既読にする。引数はジョブ名の並び。
mark_failures() {
  local job n=0 rc=0
  mkdir -p "$INBOX_STATE_DIR" || return 1
  for job in "$@"; do
    if mark_failure_read "$job"; then
      n=$((n + 1))
    else
      printf 'ERROR: 失敗の知らせを既読にできません: %s\n' "$job" >&2
      rc=1
    fi
  done
  printf '失敗の知らせを既読にしました: %s件\n' "$n"
  return "$rc"
}

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

case "$1" in
  --failures)
    if [ $# -ne 1 ]; then usage; exit 2; fi
    mark_failures $FAIL_JOBS
    exit $?
    ;;
  --failure)
    if [ $# -ne 2 ]; then usage; exit 2; fi
    if ! is_fail_job "$2"; then
      printf 'ERROR: 対象のジョブではありません: %s（対象: %s）\n' "$2" "$FAIL_JOBS" >&2
      exit 2
    fi
    mark_failures "$2"
    exit $?
    ;;
esac

rc=0
if [ "$1" = "--all" ]; then
  if [ $# -ne 1 ]; then
    usage
    exit 2
  fi
  # レポートの置き場所が無くても、失敗の知らせは既読にする。
  mark_failures $FAIL_JOBS || rc=1
  resolve_root || exit "$rc"
elif ! resolve_root; then
  printf 'ERROR: レポートの置き場所がありません: %s\n' "$REPORTS_ROOT" >&2
  exit 1
fi
mkdir -p "$INBOX_STATE_DIR" || exit 1
if ! load_read_set; then
  printf 'ERROR: 既読の記録を読めません: %s\n' "$READ_FILE" >&2
  exit 1
fi

added=0
add() {
  if is_read "$1"; then
    return 0
  fi
  printf '%s\n' "$1" >>"$READ_FILE" || return 1
  READ_SET="$READ_SET$1$NL"
  added=$((added + 1))
}

if [ "$1" = "--all" ]; then
  tab="$(printf '\t')"
  while IFS="$tab" read -r _day _seq _job path; do
    add "$path" || rc=1
  done < <(list_reports)
else
  for arg in "$@"; do
    if ! normalize_report_path "$arg"; then
      printf 'ERROR: レポートではありません: %s\n' "$arg" >&2
      rc=1
      continue
    fi
    add "$NORM_PATH" || rc=1
  done
fi

printf '既読にしました: %s件\n' "$added"
exit "$rc"
