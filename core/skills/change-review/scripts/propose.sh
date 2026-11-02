#!/bin/bash
# 定期実行が出す修正・削除の案を1件作り、作った案の id を標準出力へ出す。
# new-change.sh の前に次を行う（SKILL.md「1.」「2.2」）。
#   - 候補のフォルダ（--dest-dir）から「消える記述の行き先」の節と、移し先への追加の差分を組み立てる（destinations.sh）。
#   - メモリの削除（--memory-index）では、同じディレクトリの索引（MEMORY.md）のうち、そのメモリを指す行の削除を同じ案に入れる。
#   - 移し先の不足・安全の規則・訂正の回数・精査の判断から、区分を要確認にする。
# 使い方: propose.sh --kind <修正|削除> --target <対象の絶対パス> --diff-file <対象の差分> --dest-dir <候補のフォルダ>
#                   --title <見出し> --source <出した元> --slug <短い名前> --reason <理由> [--check <反映後の確かめ方>]
#                   [--id-prefix <ジョブ名|会話>] [--category <訂正リストの種類>] [--kind-reason <要確認の理由>]
#                   [--extra-target <差分に含めた他の対象>]... [--allow-root <移し先として認める親>]... [--memory-index]
#   --diff-file は追記してよい一時ファイルを渡す（索引と移し先の差分を末尾へ足す）。
# bash 3.2（macOS 標準）で動くように書く。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
kind="" target="" diff_file="" dest_dir="" title="" source_="" slug="change" reason="" check="" memory_index=0 id_prefix="会話" category="" kind_reason=""
extra_targets=()
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --id-prefix) id_prefix="${2-}"; shift 2 ;;
    --category) category="${2-}"; shift 2 ;;
    --kind-reason) kind_reason="${2-}"; shift 2 ;;
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
  if python3 -B "$SCRIPT_DIR/memory-index.py" drop "$index" "${target##*/}" >"$work/MEMORY.md" && ! cmp -s "$index" "$work/MEMORY.md"; then
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
  3) kind_reason="${kind_reason:+${kind_reason}、}消える記述の移し先の確認が必要" ;;
  *) exit 1 ;;
esac
while IFS= read -r t; do
  [ -n "$t" ] && tg+=(--target "$t")
done <"$work/targets"

# 表と差分の全対象を見て、機械で判定できる要確認の理由を足す。
for ((ti=1; ti<${#tg[@]}; ti+=2)); do
  t="${tg[$ti]}"
  case "$t" in
    */CLAUDE.md|*/rejections.md|*/corrections.md) kind_reason="${kind_reason:+${kind_reason}、}共通方針または否認・訂正リストの変更" ;;
  esac
  for protected in ${SKILL_AUDIT_PROTECTED:-security-rules commit-guard}; do
    case "$t" in */"$protected"|*/"$protected"/*) kind_reason="${kind_reason:+${kind_reason}、}安全のための規則の修正・削除" ;; esac
  done
done
if grep '^-' "$diff_file" | grep -v '^--- ' | grep -Eiq 'permissions[.]deny|gitleaks|秘密の検査'; then
  kind_reason="${kind_reason:+${kind_reason}、}安全のための記述の変更"
fi
if [ -n "$category" ] && [ "$("$SCRIPT_DIR/corrections.sh" count "$category")" -ge 2 ]; then
  kind_reason="${kind_reason:+${kind_reason}、}同じ種類が訂正リストで2回訂正された"
fi
case "$id_prefix" in 会話|feedback-mining) kind_reason="${kind_reason:+${kind_reason}、}会話または会話の履歴から作った決まりの案" ;; esac
review_kind=直してよい
[ -n "$kind_reason" ] && review_kind=要確認
args=(--id-prefix "$id_prefix" --kind "$review_kind" --kind-reason "$kind_reason" --source "$source_" --title "$title" --diff-file "$diff_file" "${tg[@]}" --reason "$reason" --slug "$slug" --section-file "$work/section.md")
[ -n "$check" ] && args+=(--check "$check")
"$SCRIPT_DIR/new-change.sh" "${args[@]}"
