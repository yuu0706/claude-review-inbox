#!/bin/bash
# 訂正リスト（承認なしで反映した変更のうち、会話の中で誤りと分かり直したものの記録）を扱う。SKILL.md「8.」。
# 使い方:
#   corrections.sh path
#       訂正リストのパスを出す。
#   corrections.sh count <種類>
#       「種類」の列が指定の値に一致する行の数を出す。訂正リストが無ければ 0 を出す。
#   corrections.sh add --id <変更の ID> --kind <種類> --target <対象> --correct <正しくは○○> [--date <YYYY-MM-DD>]
#       1行足す。訂正リストが無ければ冒頭の説明と表の見出しを作ってから足す。
# 種類は「<ジョブ名>/<修正|削除>/<対象の名前>」とする（例: skill-audit/修正/beta、memory-audit/削除/proj-a/d.md）。
# 置き場所は否認リストの隣（環境変数 CLAUDE_REVIEW_PROPOSALS、既定 ~/claude-reports/proposals）である。
# bash 3.2（macOS 標準）で動くように書く。
set -u

PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"
CORRECTIONS="$PROPOSALS_DIR/corrections.md"

# セルの中の | を \| にし、改行を空白にする。
cell() {
  local v="${1//$'\n'/ }"
  printf '%s' "${v//|/\\|}"
}

cmd="${1-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  path)
    printf '%s\n' "$CORRECTIONS"
    ;;
  count)
    if [ $# -ne 1 ] || [ -z "$1" ]; then
      printf 'ERROR: 種類を1つ指定してください\n' >&2
      exit 2
    fi
    if [ ! -f "$CORRECTIONS" ]; then
      printf '0\n'
      exit 0
    fi
    # 表の行（「| 」で始まる行）のうち、2列目（種類）が一致するものを数える。見出しと区切りの行は数えない。
    awk -v k="$(cell "$1")" '
      /^\| / {
        line = $0
        gsub(/\\\|/, "\001", line)
        n = split(line, c, "|")
        if (n < 3) next
        v = c[3]
        gsub(/^ +| +$/, "", v)
        gsub("\001", "\\|", v)
        if (v == k) cnt++
      }
      END { print cnt + 0 }' "$CORRECTIONS"
    ;;
  add)
    id="" kind="" target="" correct="" day="$(date '+%Y-%m-%d')"
    while [ $# -gt 0 ]; do
      case "$1" in
        --id) id="${2-}"; shift 2 ;;
        --kind) kind="${2-}"; shift 2 ;;
        --target) target="${2-}"; shift 2 ;;
        --correct) correct="${2-}"; shift 2 ;;
        --date) day="${2-}"; shift 2 ;;
        *) printf 'ERROR: 不明な引数です: %s\n' "$1" >&2; exit 2 ;;
      esac
    done
    if [ -z "$id" ] || [ -z "$kind" ] || [ -z "$target" ] || [ -z "$correct" ]; then
      printf 'ERROR: --id・--kind・--target・--correct は必須です\n' >&2
      exit 2
    fi
    mkdir -p "$PROPOSALS_DIR" || exit 1
    if [ ! -s "$CORRECTIONS" ]; then
      {
        printf '# 訂正リスト\n\n'
        printf '承認なしで反映した変更のうち、会話の中で誤りと分かり直したものの記録である。'
        printf '定期実行は変更を出す前にこの表を読み、訂正された変更を再び行わない。'
        printf '同じ「種類」の行が2行になったら、以後その種類の変更は承認待ちに回す。\n\n'
        printf '| 変更の ID | 種類 | 対象 | 正しくは | 訂正日 |\n'
        printf '| --- | --- | --- | --- | --- |\n'
      } >"$CORRECTIONS" || exit 1
    fi
    printf '| %s | %s | %s | %s | %s |\n' "$(cell "$id")" "$(cell "$kind")" "$(cell "$target")" "$(cell "$correct")" "$(cell "$day")" >>"$CORRECTIONS" || exit 1
    printf '%s\n' "$CORRECTIONS"
    ;;
  *)
    printf '使い方: corrections.sh path | count <種類> | add --id <ID> --kind <種類> --target <対象> --correct <正しくは○○> [--date <日付>]\n' >&2
    exit 2
    ;;
esac
