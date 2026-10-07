#!/bin/bash
# Claude Code の PostToolUse フック。メモリのファイルを Write か Edit で書いたとき、
# frontmatter の metadata の下へ作成したリポジトリ（repo・repo_path）を足す。repo: が既にあれば書き換えない。
# フックの失敗で作業を止めないため、どんな場合も終了コード0で、標準出力へ何も出さない。
# bash 3.2（macOS 標準）で動くように書く。
set -u
exec >/dev/null 2>&1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 0
. "$SCRIPT_DIR/memory-repo-lib.sh" || exit 0
JQ="/usr/bin/jq"
[ -x "$JQ" ] || JQ="jq"

input="$(cat)" || exit 0
fields="$(printf '%s' "$input" | "$JQ" -r '[.tool_name // "", .tool_input.file_path // "", .cwd // ""] | join("\u001f")')" || exit 0
IFS=$'\037' read -r tool file cwd <<EOF
$fields
EOF

case "$tool" in
  Write|Edit) ;;
  *) exit 0 ;;
esac
case "$file" in
  */projects/*/memory/*.md) ;;
  *) exit 0 ;;
esac
[ "${file##*/}" = "MEMORY.md" ] && exit 0
[ -n "$cwd" ] || exit 0

if top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
  repo="${top##*/}"
  repo_path="$top"
else
  repo="なし"
  repo_path="$cwd"
fi

memory_add_repo "$file" "$repo" "$repo_path"
exit 0
