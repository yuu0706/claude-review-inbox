#!/bin/bash
# 修正・削除の案に付ける「消える記述の行き先」の節と、移し先への追加の差分を組み立てる（SKILL.md「2.2」）。
# 定期実行の claude が候補ごとのフォルダに書いた次の2つを読む。
#   table.md   行き先の表（| No | 消える記述 | 行き先 | 場所 | の Markdown の表）。表の行（| で始まる行）だけを使う。
#   moves.tsv  「移し先の絶対パス<TAB>書き足した後の版のファイル名（同じフォルダの中）」を1行1件。無くてもよい。
# 使い方: destinations.sh --dir <候補のフォルダ> --diff <案の差分のファイル> --section <節の出力先> --targets <移し先の一覧の出力先>
#                         [--extra-rows <表の行を足すファイル>] [--allow-root <移し先として認める親>]...
#   --diff     移し先への追加の差分を末尾へ足す。
#   --section  「## 消える記述の行き先」の節を書く（上書き）。
#   --targets  差分に入れた移し先の絶対パスを1行1件で足す。
#   --extra-rows  シェルが足す表の行（「| <記述> | <行き先> | <場所> |」の形。No は続きの番号を振る）。
# 終了コード: 0 表と差分がそろった、3 移し先の確認が必要（表が無い・候補なし・移し先の差分が作れない）、2 引数の誤り
# bash 3.2（macOS 標準）で動くように書く。
set -u

#        destinations.sh --print-rule <行き先の表を書くフォルダ>
#   --print-rule  定期実行の claude への依頼文に入れる、表と移し先の書き方の規則を標準出力へ出す。

if [ "${1-}" = --print-rule ]; then
  base="${2-}"
  if [ -z "$base" ]; then
    printf 'ERROR: --print-rule には行き先の表を書くフォルダが必要です\n' >&2
    exit 2
  fi
  cat <<EOF
既存の行を変える・消す修正と削除の候補ごとに、消える記述の行き先を ${base} の下のフォルダに書く。フォルダの位置は、候補の元の絶対パスを、書き込み先と同じ規則（.claude で始まる要素は先頭のドットを外す）で ${base} の下へ写したものとする（例: 元が /a/.claude/m/x.md なら ${base}/a/claude/m/x.md/）。
そのフォルダの table.md に「| No | 消える記述 | 行き先 | 場所 |」の Markdown の表を書く。消える記述は、差分の - 行のうち意味のまとまり（決まり・事実・手順・理由）ごとに1行とし、元の記述のどれに当たるかが分かる1文の要約にする。
行き先は「記載あり」「記載あり（ただし対象のほうが古い）」「一部のみ記載あり（◯◯は無い）」「記載なし → この案で移す」「決まりではない（リンク・経緯の記録など）」のどれかにする。「記載あり」は行き先のファイルを実際に読み、該当の行を確かめたときだけ書き、場所に \`<絶対パス>:<行>\` を書く。一部しか無い場合は、無い部分を「記載なし」の行として別に立てる。
「記載なし → この案で移す」の場所は「移し先 \`<絶対パス>\`（<節の名前>）」とする。同じフォルダに移し先のファイルへ書き足した後の全文を置き、moves.tsv に「移し先の絶対パス<TAB>そのファイル名」を1行1件書く。移し先の既存の行は変えない。移し先は CLAUDE.md・スキル・メモリのどれでもよいが、元のファイルを直接は直さない。移し先の候補が見つからなければ、場所に「（候補なし）」と書く。
EOF
  exit 0
fi

dir="" diff_file="" section="" targets_out="" extra=""
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="${2-}"; shift 2 ;;
    --diff) diff_file="${2-}"; shift 2 ;;
    --section) section="${2-}"; shift 2 ;;
    --targets) targets_out="${2-}"; shift 2 ;;
    --extra-rows) extra="${2-}"; shift 2 ;;
    --allow-root) roots+=("${2%/}"); shift 2 ;;
    *) printf 'ERROR: 不明な引数です: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [ -z "$dir" ] || [ -z "$diff_file" ] || [ -z "$section" ] || [ -z "$targets_out" ]; then
  printf 'ERROR: --dir・--diff・--section・--targets は必須です\n' >&2
  exit 2
fi

problems="$(mktemp "${TMPDIR:-/tmp}/destinations-problems.XXXXXX")" || exit 2
rows="$(mktemp "${TMPDIR:-/tmp}/destinations-rows.XXXXXX")" || exit 2
moved="$(mktemp "${TMPDIR:-/tmp}/destinations-moved.XXXXXX")" || exit 2
one="$(mktemp "${TMPDIR:-/tmp}/destinations-one.XXXXXX")" || exit 2
trap 'rm -f "$problems" "$rows" "$moved" "$one"' EXIT

# 表の本体の行（見出しと区切りを除く）を「記述<TAB>行き先<TAB>場所」で取り出す。
table_rows() {
  awk -F'|' '
    /^[[:space:]]*\|/ {
      if ($0 ~ /^[[:space:]]*\|[[:space:]:-]+\|/) next
      n = NF
      if (n < 5) next
      c2 = $3; c3 = $4; c4 = $5
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", c2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", c3)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", c4)
      if (c2 == "消える記述") next
      print c2 "\t" c3 "\t" c4
    }' "$1"
}

if [ -f "$dir/table.md" ] && [ ! -L "$dir/table.md" ]; then
  table_rows "$dir/table.md" >"$rows"
fi
if [ ! -s "$rows" ]; then
  printf -- '- 行き先の表が作られなかった（%s/table.md）。消える記述が CLAUDE.md・スキル・メモリに残っているかを確かめる必要がある\n' "$dir" >>"$problems"
fi
if [ -n "$extra" ] && [ -f "$extra" ]; then
  awk -F'|' 'NF >= 4 { a = $2; b = $3; c = $4
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", a); gsub(/^[[:space:]]+|[[:space:]]+$/, "", b); gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
    print a "\t" b "\t" c }' "$extra" >>"$rows"
fi

# 移し先として認める場所かを判定する。
allowed_dest() {
  local p="$1" r
  case "$p" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$p" in *..*) return 1 ;; esac
  [ "${#roots[@]}" -eq 0 ] && return 0
  for r in "${roots[@]}"; do
    case "$p" in "$r"/*) return 0 ;; esac
  done
  return 1
}

# 移し先への追加の差分を作る。既存の行を変えない・消さない差分だけを認める。
if [ -f "$dir/moves.tsv" ] && [ ! -L "$dir/moves.tsv" ]; then
  while IFS=$'\t' read -r mdest mfile || [ -n "$mdest" ]; do
    [ -n "$mdest" ] || continue
    case "$mfile" in
      ''|*/*|*..*) printf -- '- 移し先 `%s`: 書き足した後の版のファイル名が正しくない（%s）\n' "$mdest" "$mfile" >>"$problems"; continue ;;
    esac
    if ! allowed_dest "$mdest"; then
      printf -- '- 移し先 `%s`: 移し先として認める場所ではない\n' "$mdest" >>"$problems"; continue
    fi
    if [ ! -f "$mdest" ]; then
      printf -- '- 移し先 `%s`: ファイルが無い（新しいファイルへは移さない）\n' "$mdest" >>"$problems"; continue
    fi
    if [ ! -f "$dir/$mfile" ] || [ -L "$dir/$mfile" ]; then
      printf -- '- 移し先 `%s`: 書き足した後の版 %s が無い\n' "$mdest" "$mfile" >>"$problems"; continue
    fi
    if diff -u "$mdest" "$dir/$mfile" | tail -n +3 | grep -q '^-'; then
      printf -- '- 移し先 `%s`: 書き足した後の版が既存の行を変えている（追加だけを認める）\n' "$mdest" >>"$problems"; continue
    fi
    diff -u -- "$mdest" "$dir/$mfile" >"$one"
    if [ $? -ne 1 ]; then
      printf -- '- 移し先 `%s`: 書き足した後の版が元と同じである\n' "$mdest" >>"$problems"; continue
    fi
    awk -v label="$mdest" '
      NR == 1 && /^--- / { print "--- " label; next }
      NR == 2 && /^\+\+\+ / { print "+++ " label; next }
      { print }' "$one" >>"$diff_file"
    printf '%s\n' "$mdest" >>"$moved"
    grep -Fxq -- "$mdest" "$targets_out" 2>/dev/null || printf '%s\n' "$mdest" >>"$targets_out"
  done <"$dir/moves.tsv"
fi

# 「記載なし」の行ごとに、移し先の差分がそろっているかを確かめる。
no=0
while IFS=$'\t' read -r what where place; do
  no=$((no + 1))
  case "$where" in
    *記載なし*)
      case "$place" in
        *候補なし*)
          printf -- '- No %s: 移し先の候補が無い。移し先を決めるか、移さずに捨てるかの判断が必要\n' "$no" >>"$problems" ;;
        *)
          mpath="$(printf '%s' "$place" | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p')"
          if [ -z "$mpath" ] || ! grep -Fxq -- "$mpath" "$moved"; then
            printf -- '- No %s: 「記載なし」だが、移し先への追加の差分がこの案に無い\n' "$no" >>"$problems"
          fi ;;
      esac ;;
  esac
done <"$rows"

{
  printf '## 消える記述の行き先\n\n'
  printf '| No | 消える記述 | 行き先 | 場所 |\n'
  printf '| --- | --- | --- | --- |\n'
  awk -F'\t' '{ printf "| %d | %s | %s | %s |\n", NR, $1, $2, $3 }' "$rows"
  printf '\n承認すると、差分の全体（移し先への追記を含む）をそのまま反映する。移さずに捨てたい記述があれば、承認せずに保留にし、メモに「No 3 は移さない」のように書く（案を作り直す）。\n'
  if [ -s "$problems" ]; then
    printf '\n### 移し先の確認が必要な点\n\n'
    cat "$problems"
  fi
} >"$section"

[ -s "$problems" ] && exit 3
exit 0
