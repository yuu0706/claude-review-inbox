#!/bin/bash
# 承認待ちの案を状態ごとに数え、次の2行を標準出力へ出す。案が無くても2行出す。
#   pending<TAB><件数><TAB><最も古い pending の id（無ければ空）>
#   approved<TAB><件数>
# approved は「承認済み・未反映」（status が approved のもの）である。
# SessionStart フックから毎回呼ばれるため、外部コマンドは awk を1回だけ起動する。どんな失敗でも終了コード0とする。
# 置き場所: CLAUDE_REVIEW_PROPOSALS、無ければ ${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals
# bash 3.2（macOS 標準）で動くように書く。

dir="${CLAUDE_REVIEW_PROPOSALS:-${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals}"
files=()
for f in "$dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.md; do
  [ -f "$f" ] && [ ! -L "$f" ] && files+=("$f")
done
if [ "${#files[@]}" -eq 0 ]; then
  printf 'pending\t0\t\napproved\t0\n'
  exit 0
fi
awk '
  function trim(v) {
    sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
    if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
    return v
  }
  function flush() {
    if (state != 2 || id == "") return
    if (status == "pending") { np++; if (oldest == "" || id < oldest) oldest = id }
    else if (status == "approved") na++
  }
  FNR == 1 {
    if (NR > 1) flush()
    state = ($0 ~ /^---[ \t\r]*$/) ? 1 : 0
    id = ""; status = ""
    next
  }
  state == 1 {
    if ($0 ~ /^---[ \t\r]*$/) { state = 2; next }
    if ($0 ~ /^id:/) { v = $0; sub(/^id:/, "", v); id = trim(v) }
    else if ($0 ~ /^status:/) { v = $0; sub(/^status:/, "", v); status = trim(v) }
  }
  END {
    if (NR > 0) flush()
    printf "pending\t%d\t%s\napproved\t%d\n", np, oldest, na
  }' "${files[@]}" 2>/dev/null || printf 'pending\t0\t\napproved\t0\n'
exit 0
