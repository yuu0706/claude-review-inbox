#!/bin/bash
# SessionStart フック。承認待ちと、承認済みで未反映の案があれば1行だけ出す。どちらも0件なら何も出さない。
# 出力例: 承認待ち 2件・承認済み・未反映 1件（http://127.0.0.1:8010/）
# どんな失敗でも終了コード0で何も出さない。
# 件数は change-review の scripts/count.sh で数える。このファイルからの相対位置で探す。

main() {
  local dir count key n _oldest pending=0 approved=0 out="" port
  dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || return 0
  count="$dir/../skills/change-review/scripts/count.sh"
  [ -f "$count" ] || return 0
  while IFS=$'\t' read -r key n _oldest; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    case "$key" in
      pending) pending="$n" ;;
      approved) approved="$n" ;;
    esac
  done < <(bash "$count")
  [ "$pending" -gt 0 ] && out="承認待ち ${pending}件"
  [ "$approved" -gt 0 ] && out="${out}${out:+・}承認済み・未反映 ${approved}件"
  [ -n "$out" ] || return 0
  port="${CLAUDE_REVIEW_PORT:-8010}"
  printf '%s（http://127.0.0.1:%s/）\n' "$out" "$port"
}

main 2>/dev/null
exit 0
