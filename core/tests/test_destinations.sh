#!/bin/bash
# requires: change-review
# 「消える記述の行き先」の共通部品（change-review の destinations.sh・propose.sh・memory-index.py）の検査。
# 一時ディレクトリだけを使う。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
CR="$REPO/core/skills/change-review/scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/destinations-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export CLAUDE_REVIEW_PROPOSALS="$WORK/proposals"
export CLAUDE_REVIEW_CHANGES_LOG="$WORK/log.md"
NL=$'\n'

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

ROOT="$WORK/root"
mkdir -p "$ROOT" "$WORK/outside" "$WORK/cand"
printf '# 規則\n- 既存\n' >"$ROOT/CLAUDE.md"
printf 'o\n' >"$WORK/outside/x.md"

run_dest() {
  : >"$WORK/diff"
  : >"$WORK/targets"
  "$CR/destinations.sh" --dir "$WORK/cand" --diff "$WORK/diff" --section "$WORK/section" --targets "$WORK/targets" \
    --allow-root "$ROOT" "$@"
}

echo "== --print-rule"
out="$("$CR/destinations.sh" --print-rule "$WORK/base")"
check "表の見出しと書き先を含む" 'printf "%s" "$out" | grep -Fq "| No | 消える記述 | 行き先 | 場所 |" && printf "%s" "$out" | grep -Fq "$WORK/base の下のフォルダに書く"'
"$CR/destinations.sh" --print-rule 2>/dev/null
check "書き先が無ければ終了コード2" '[ $? -eq 2 ]'

echo "== 表が無い"
run_dest
rc=$?
check "終了コード3" '[ "$rc" -eq 3 ]'
check "表が作られなかったことを書く" 'grep -Fq "行き先の表が作られなかった" "$WORK/section" && grep -Fxq "## 消える記述の行き先" "$WORK/section"'

echo "== 表と移し先がそろっている"
cat >"$WORK/cand/table.md" <<EOF
前置きの文は使わない
| No | 消える記述 | 行き先 | 場所 |
| --- | --- | --- | --- |
| 1 | 決まり A | 記載あり | \`$ROOT/CLAUDE.md:2\` |
| 2 | 決まり B | 記載なし → この案で移す | 移し先 \`$ROOT/CLAUDE.md\`（規則） |
EOF
printf '# 規則\n- 既存\n- 決まり B\n' >"$WORK/cand/CLAUDE.md"
printf '%s\t%s\n' "$ROOT/CLAUDE.md" CLAUDE.md >"$WORK/cand/moves.tsv"
printf '| 索引の行 | 決まりではない（索引の行） | `%s` |\n' "$ROOT/MEMORY.md" >"$WORK/extra"
run_dest --extra-rows "$WORK/extra"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "表の行だけを使い、番号を振り直す" '! grep -Fq "前置き" "$WORK/section" && grep -Fq "| 2 | 決まり B | 記載なし → この案で移す |" "$WORK/section" && grep -Fq "| 3 | 索引の行 |" "$WORK/section"'
check "移し先の差分の見出しは元の絶対パス" 'grep -Fxq -- "--- $ROOT/CLAUDE.md" "$WORK/diff" && grep -Fxq "+++ $ROOT/CLAUDE.md" "$WORK/diff" && grep -Fxq "+- 決まり B" "$WORK/diff"'
check "移し先を targets に出す" '[ "$(cat "$WORK/targets")" = "$ROOT/CLAUDE.md" ]'
check "移し先のファイルは変えない" '[ "$(cat "$ROOT/CLAUDE.md")" = "# 規則${NL}- 既存" ]'

echo "== 移し先が既存の行を変える"
printf '# 規則\n- 変えた\n- 決まり B\n' >"$WORK/cand/CLAUDE.md"
run_dest
rc=$?
check "終了コード3" '[ "$rc" -eq 3 ]'
check "差分に入れない" '[ ! -s "$WORK/diff" ] && [ ! -s "$WORK/targets" ]'
check "理由と、記載なしの行に差分が無いことを書く" 'grep -Fq "既存の行を変えている" "$WORK/section" && grep -Fq "No 2: 「記載なし」だが、移し先への追加の差分がこの案に無い" "$WORK/section"'

echo "== 移し先が範囲外・.. を含む・ファイル名が不正"
printf 'o\nadd\n' >"$WORK/cand/x.md"
printf '%s\t%s\n' "$WORK/outside/x.md" x.md "$ROOT/../outside/x.md" x.md "$ROOT/CLAUDE.md" ../x.md >"$WORK/cand/moves.tsv"
run_dest
rc=$?
check "終了コード3" '[ "$rc" -eq 3 ]'
check "差分に入れない" '[ ! -s "$WORK/diff" ]'
check "それぞれの理由を書く" '[ "$(grep -c "移し先として認める場所ではない" "$WORK/section")" = "2" ] && grep -Fq "ファイル名が正しくない" "$WORK/section"'

echo "== 候補なし"
printf '| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | 事実 C | 記載なし → この案で移す | （候補なし） |\n' >"$WORK/cand/table.md"
rm -f "$WORK/cand/moves.tsv"
run_dest
rc=$?
check "終了コード3で、候補が無いことを書く" '[ "$rc" -eq 3 ] && grep -Fq "No 1: 移し先の候補が無い" "$WORK/section"'

echo "== memory-index.py"
M="$WORK/MEMORY.md"
printf -- '- [G](g.md) — g\n- [A](a.md) — a\n- [H](h.md) — h\n' >"$M"
check "drop は指定したファイルを指す行だけを除く" '[ "$(python3 "$CR/memory-index.py" drop "$M" g.md)" = "- [A](a.md) — a${NL}- [H](h.md) — h" ]'
printf -- '- [A](a.md) — a 改\n- [N](n.md) — n\n' >"$WORK/staged.md"
check "keep は消された行のうち指定したファイルを指す行だけを戻す" '[ "$(python3 "$CR/memory-index.py" keep "$M" "$WORK/staged.md" g.md)" = "- [G](g.md) — g${NL}- [A](a.md) — a 改${NL}- [N](n.md) — n" ]'
python3 "$CR/memory-index.py" 2>/dev/null
check "引数が足りなければ終了コード2" '[ $? -eq 2 ]'

echo "== propose.sh"
MD="$WORK/mem"
mkdir -p "$MD" "$WORK/cand2"
printf 'g1\n' >"$MD/g.md"
printf -- '- [G](g.md) — g\n- [A](a.md) — a\n' >"$MD/MEMORY.md"
"$CR/diff-label.sh" "$MD/g.md" /dev/null "$MD/g.md" >"$WORK/pdiff"
printf '| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | g1 | 記載あり | `%s:2` |\n' "$ROOT/CLAUDE.md" >"$WORK/cand2/table.md"
id="$("$CR/propose.sh" --kind 削除 --target "$MD/g.md" --diff-file "$WORK/pdiff" --dest-dir "$WORK/cand2" --memory-index \
  --allow-root "$ROOT" --title "g の削除" --source "検査" --slug test --reason "重複")"
p="$CLAUDE_REVIEW_CHANGES_LOG"
check "案が作られる" '[ -f "$p" ] && grep -Fxq -- "- 状態: 未対応" "$p"'
check "索引の行の削除と表の行が入る" 'grep -Fq "$MD/MEMORY.md" "$p" && grep -Fxq -- "-- [G](g.md) — g" "$p" && grep -Fq "| 2 | 索引 MEMORY.md の、このメモリを指す行 |" "$p"'
check "確認の印は付かない" 'grep -Fxq -- "- 直したいこと: g の削除" "$p"'
check "索引のファイルは変えない" '[ "$(cat "$MD/MEMORY.md")" = "- [G](g.md) — g${NL}- [A](a.md) — a" ]'
"$CR/propose.sh" --kind 削除 --target "$MD/g.md" 2>/dev/null
check "必須の引数が無ければ終了コード2" '[ $? -eq 2 ]'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
