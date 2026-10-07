#!/bin/bash
# diff -u の出力の見出しの2行を、指定したパス（元のファイルの絶対パス）に置き換えて標準出力へ出す。
# 使い方: diff-label.sh <元のファイル> <直した後のファイル> <見出しに書くパス>
#   削除の差分は <直した後のファイル> に /dev/null を、追加の差分は <元のファイル> に /dev/null を渡す。
# 終了コード: 差分なし 0、差分あり 1、失敗 2（diff と同じ）
set -u

if [ $# -ne 3 ]; then
  printf 'usage: diff-label.sh <old> <new> <label>\n' >&2
  exit 2
fi
out="$(diff -u -- "$1" "$2")"
rc=$?
[ "$rc" -eq 1 ] || exit "$rc"
printf '%s\n' "$out" | awk -v label="$3" '
  NR == 1 && /^--- / { print "--- " label; next }
  NR == 2 && /^\+\+\+ / { print "+++ " label; next }
  { print }'
exit 1
