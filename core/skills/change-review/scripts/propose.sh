#!/bin/bash
# 定期実行が出す修正・削除の案を1件作り、作った案の id を標準出力へ出す。
# new-proposal.sh の前に次を行う（SKILL.md「1.」「2.2」）。
#   - 候補のフォルダ（--dest-dir）から「消える記述の行き先」の節と、移し先への追加の差分を組み立てる（destinations.sh）。
#   - メモリの削除（--memory-index）では、同じディレクトリの索引（MEMORY.md）のうち、そのメモリを指す行の削除を同じ案に入れる。
#   - 移し先の確認が必要なとき（destinations.sh の終了コード 3）は、見出しの末尾に「（移し先の確認が必要）」を付ける。
# 使い方: propose.sh --kind <修正|削除> --target <対象の絶対パス> --diff-file <対象の差分> --dest-dir <候補のフォルダ>
#                   --title <見出し> --source <出した元> --slug <短い名前> --reason <理由> [--check <反映後の確かめ方>]
#                   [--extra-target <差分に含めた他の対象>]... [--allow-root <移し先として認める親>]... [--memory-index]
#   --diff-file は追記してよい一時ファイルを渡す（索引と移し先の差分を末尾へ足す）。
# bash 3.2（macOS 標準）で動くように書く。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
kind="" target="" diff_file="" dest_dir="" title="" source_="" slug="change" reason="" check="" memory_index=0
extra_targets=()
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) kind="${2-}"; shift 2 ;;
    --target) target="${2-}"; shift 2 ;;
    --diff-file) diff_file="${2-}"; shift 2 ;;
    --dest-dir) dest_dir="${2-}"; shift 2 ;;
    --title) title="${2-}"; shift 2 ;;
    --source) source_="${2-}"; shift 2 ;;
    --slug) slug="${2-}"; shift 2 ;;
    --reason) reason="${2-}"; shift 2 ;;
    --check) check="${2-}"; shift 2 ;;
    --extra-target) extra_targets+=("${2-}"); shift 2 ;;
    --allow-root) roots+=(--allow-root "${2-}"); shift 2 ;;
    --memory-index) memory_index=1; shift ;;
    *) printf 'ERROR: 不明な引数です: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [ -z "$kind" ] || [ -z "$target" ] || [ -z "$diff_file" ] || [ -z "$dest_dir" ] || [ -z "$title" ] || [ -z "$source_" ]; then
  printf 'ERROR: --kind・--target・--diff-file・--dest-dir・--title・--source は必須です\n' >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/propose.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
tg=(--target "$target")
for t in ${extra_targets[@]+"${extra_targets[@]}"}; do tg+=(--target "$t"); done
: >"$work/extra-rows"

# メモリの削除では、そのメモリを指す索引の行の削除を同じ案に入れる。
index="${target%/*}/MEMORY.md"
if [ "$memory_index" -eq 1 ] && [ "$kind" = 削除 ] && [ "$index" != "$target" ] && [ -f "$index" ] && [ ! -L "$index" ]; then
  if python3 "$SCRIPT_DIR/memory-index.py" drop "$index" "${target##*/}" >"$work/MEMORY.md" && ! cmp -s "$index" "$work/MEMORY.md"; then
    "$SCRIPT_DIR/diff-label.sh" "$index" "$work/MEMORY.md" "$index" >>"$diff_file"
    tg+=(--target "$index")
    printf '| 索引 MEMORY.md の、このメモリを指す行 | 決まりではない（索引の行。ファイルと同じ案で消す） | `%s` |\n' "$index" >>"$work/extra-rows"
  fi
fi

: >"$work/targets"
"$SCRIPT_DIR/destinations.sh" --dir "$dest_dir" --diff "$diff_file" --section "$work/section.md" \
  --targets "$work/targets" --extra-rows "$work/extra-rows" ${roots[@]+"${roots[@]}"}
rc=$?
case "$rc" in
  0) ;;
  3) title="${title}（移し先の確認が必要）" ;;
  *) exit 1 ;;
esac
while IFS= read -r t; do
  [ -n "$t" ] && tg+=(--target "$t")
done <"$work/targets"

args=(--source "$source_" --title "$title" --diff-file "$diff_file" "${tg[@]}" --reason "$reason" --slug "$slug" --section-file "$work/section.md")
[ -n "$check" ] && args+=(--check "$check")
"$SCRIPT_DIR/new-proposal.sh" "${args[@]}"
