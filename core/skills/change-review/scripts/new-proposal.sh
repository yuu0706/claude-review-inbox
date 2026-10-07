#!/bin/bash
# 承認待ちの案を1件作り、作ったファイルの id を標準出力へ出す。定期実行のスクリプトがシェルで案を作るために使う。
# 使い方: new-proposal.sh --source <出した元> --title <見出し> --diff-file <差分のファイル>
#                        --target <対象の絶対パス> [--target ...] [--reason <理由>] [--check <反映後の確かめ方>] [--slug <短い名前>]
#                        [--section-file <理由の後に入れる節（「消える記述の行き先」等）>]
# 置き場所: CLAUDE_REVIEW_PROPOSALS、無ければ ${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals
# ファイル名は <YYYY-MM-DD>-<連番2桁>-<短い名前>.md。連番はその日の通し番号で、置き場所の .lock で排他する。
# bash 3.2（macOS 標準）で動くように書く。
set -u

dir="${CLAUDE_REVIEW_PROPOSALS:-${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals}"
source_="" title="" diff_file="" reason="" check="" slug="change" section_file=""
targets=()
while [ $# -gt 0 ]; do
  case "$1" in
    --source) source_="${2-}"; shift 2 ;;
    --title) title="${2-}"; shift 2 ;;
    --diff-file) diff_file="${2-}"; shift 2 ;;
    --target) targets+=("${2-}"); shift 2 ;;
    --reason) reason="${2-}"; shift 2 ;;
    --check) check="${2-}"; shift 2 ;;
    --slug) slug="${2-}"; shift 2 ;;
    --section-file) section_file="${2-}"; shift 2 ;;
    *) printf 'ERROR: 不明な引数です: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [ -z "$source_" ] || [ -z "$title" ] || [ -z "$diff_file" ] || [ "${#targets[@]}" -eq 0 ]; then
  printf 'ERROR: --source・--title・--diff-file・--target は必須です\n' >&2
  exit 2
fi
if [ -n "$section_file" ] && [ ! -f "$section_file" ]; then
  printf 'ERROR: 節のファイルがありません: %s\n' "$section_file" >&2
  exit 2
fi
if [ ! -f "$diff_file" ]; then
  printf 'ERROR: 差分のファイルがありません: %s\n' "$diff_file" >&2
  exit 2
fi
# 短い名前は英小文字・数字・ハイフンに限る。
slug="$(printf '%s' "$slug" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)"
[ -n "$slug" ] || slug="change"
# 見出しと frontmatter の値は1行にする。
title="$(printf '%s' "$title" | tr '\r\n' '  ')"
source_="$(printf '%s' "$source_" | tr '\r\n' '  ')"

mkdir -p "$dir" || exit 1
lock="$dir/.lock"
i=0
until mkdir "$lock" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 50 ]; then
    printf 'ERROR: 置き場所の排他を取れません: %s\n' "$lock" >&2
    exit 1
  fi
  sleep 0.1
done
trap 'rmdir "$lock" 2>/dev/null' EXIT

day="$(date '+%Y-%m-%d')"
n=0
for f in "$dir/$day"-[0-9][0-9]*.md; do
  [ -e "$f" ] || continue
  s="${f##*/}"
  s="${s:11:2}"
  case "$s" in
    [0-9][0-9]) s=$((10#$s)); [ "$s" -gt "$n" ] && n="$s" ;;
  esac
done
n=$((n + 1))
if [ "$n" -gt 99 ]; then
  printf 'ERROR: 同じ日の連番が99を超えます\n' >&2
  exit 1
fi
seq="$(printf '%02d' "$n")"
id="$day-$seq"
path="$dir/$id-$slug.md"
tmp="$dir/.tmp-$id.$$"

# 差分にコードブロックの区切り（```）が含まれていても崩れないよう、区切りを長くする。
fence='```'
while grep -q "^$fence" "$diff_file"; do fence="$fence\`"; done

{
  printf -- '---\n'
  printf 'id: %s\n' "$id"
  printf 'status: pending\n'
  printf 'created: %s\n' "$(date '+%Y-%m-%d %H:%M')"
  printf 'source: %s\n' "$source_"
  printf 'targets:\n'
  for t in "${targets[@]}"; do printf '  - %s\n' "$t"; done
  printf 'note: ""\n'
  printf -- '---\n\n'
  printf '# %s\n\n' "$title"
  printf '## 理由\n\n%s\n\n' "${reason:-記載なし}"
  if [ -n "$section_file" ]; then
    cat "$section_file"
    [ -n "$(tail -c1 "$section_file")" ] && printf '\n'
    printf '\n'
  fi
  printf '## 差分\n\n%sdiff\n' "$fence"
  cat "$diff_file"
  [ -s "$diff_file" ] && [ -n "$(tail -c1 "$diff_file")" ] && printf '\n'
  printf '%s\n\n' "$fence"
  printf '## 反映後の確かめ方\n\n%s\n' "${check:-対象のファイルが差分のとおりになっていることを確かめる。}"
} >"$tmp" && mv "$tmp" "$path" || { rm -f "$tmp"; exit 1; }
printf '%s\n' "$id"
