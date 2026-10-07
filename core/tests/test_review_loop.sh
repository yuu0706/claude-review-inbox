#!/bin/bash
# review-loop（週1回の棚卸し）の検査。HOME を一時ディレクトリに差し替え、claude を偽のコマンドにして実行する。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
RUN="$REPO/core/skills/review-loop/scripts/run.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-loop-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
unset CLAUDE_REPORTS_ROOT CLAUDE_REVIEW_PROPOSALS CLAUDE_REVIEW_STATE CLAUDE_REVIEW_LOOP_MODEL CLAUDE_REVIEW_LOOP_EFFORT
export CHANGE_REVIEW_SCRIPTS="$REPO/core/skills/change-review/scripts"
PDIR="$HOME/claude-reports/proposals"
STATE="$HOME/.local/state/claude-review-inbox/review-loop"
RDIR="$HOME/claude-reports/review-loop"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽の HOME。自作のスキル alpha、外部を指すリンクのスキル linked、.trash、メモリ2つ。
SK="$HOME/.claude/skills"
mkdir -p "$SK/alpha" "$SK/.trash/old" "$WORK/external/linked" "$HOME/.claude/projects/p1/memory" "$HOME/.local/bin"
printf '# alpha\nline1\n' >"$SK/alpha/SKILL.md"
printf 'x\n' >"$SK/.trash/old/SKILL.md"
printf '# linked\n' >"$WORK/external/linked/SKILL.md"
ln -s "$WORK/external/linked" "$SK/linked"
ln -s "$REPO/core/skills/change-review" "$SK/change-review"
M="$HOME/.claude/projects/p1/memory"
printf 'm1\n' >"$M/a.md"
printf 'm2\n' >"$M/b.md"
printf 'm3\n' >"$M/c.md"
S_SK="$HOME/claude/skills/alpha"
S_M="$HOME/claude/projects/p1/memory"

# 偽の claude。引数を記録し、依頼文から書き込み先を読んで STAGE に入れ、FAKE_HOOK を実行する。
export FAKE_ARGS="$WORK/args"
cat >"$HOME/.local/bin/claude" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_ARGS"
p="$2"
STAGE="${p##*書き込み先 }"
STAGE="${STAGE%%へ書く*}"
STAGE="${STAGE%% *}"
export STAGE
[ -n "${FAKE_HOOK:-}" ] && eval "$FAKE_HOOK"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$HOME/.local/bin/claude"

echo "== --dry-run"
out="$("$RUN" --dry-run)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "自作のスキルとメモリだけを対象にする" '[ "$(printf "%s\n" "$out" | grep -c "^TARGET: ")" = "2" ] && printf "%s" "$out" | grep -Fxq "TARGET: $SK/alpha" && printf "%s" "$out" | grep -Fxq "TARGET: $M"'
check "claude を起動しない" '[ ! -f "$FAKE_ARGS" ]'
check "案も結果も作らない" '[ ! -d "$PDIR" ] && [ -z "$(ls "$RDIR")" ]'
check "--model を付けない（未指定）" '! printf "%s" "$out" | grep -Fq -- "'"'"'--model'"'"'"'
out="$(CLAUDE_REVIEW_LOOP_MODEL=sonnet CLAUDE_REVIEW_LOOP_EFFORT=low "$RUN" --dry-run)"
check "環境変数があれば --model と --effort を付ける" 'printf "%s" "$out" | grep -Fq -- "'"'"'--model'"'"' '"'"'sonnet'"'"'" && printf "%s" "$out" | grep -Fq -- "'"'"'--effort'"'"' '"'"'low'"'"'"'

echo "== 追加は書き戻し、修正・削除・新しいファイルは案にする"
HOOK='mkdir -p "$STAGE'"$S_SK"'" "$STAGE'"$S_M"'"
printf "# alpha\nline1\nline2\n" >"$STAGE'"$S_SK"'/SKILL.md"
printf "m1-changed\n" >"$STAGE'"$S_M"'/a.md"
printf "new\n" >"$STAGE'"$S_M"'/new.md"
printf "%s\t%s\n" "'"$M"'/c.md" "重複している" >"$STAGE/deletions.tsv"
printf "要点1\n" >"$STAGE/summary.md"'
FAKE_HOOK="$HOOK" "$RUN"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "追加だけの変更は書き戻す" '[ "$(cat "$SK/alpha/SKILL.md")" = "$(printf "# alpha\nline1\nline2")" ]'
check "修正は元のファイルを変えない" '[ "$(cat "$M/a.md")" = "m1" ]'
check "削除の候補は消さない" '[ -f "$M/c.md" ]'
check "新しいファイルは作らない" '[ ! -e "$M/new.md" ]'
check "修正・削除・新しいファイルが案になる" '[ "$(ls "$PDIR"/*.md | wc -l | tr -d " ")" = "3" ] && grep -lq "^status: pending" "$PDIR"/*.md'
check "案の差分の見出しが元のパス" 'grep -Fq -- "--- $M/a.md" "$PDIR"/*.md && grep -Fq "+++ $M/new.md" "$PDIR"/*.md'
check "否認リストのパスが依頼文に入る" 'grep -Fq "$PDIR/rejections.md" "$FAKE_ARGS"'
check "pending と hold の扱いが依頼文に入る" 'grep -q "pending の案と同じ変更は作らない" "$FAKE_ARGS" && grep -q "hold の案は、note の指摘を反映した改訂版" "$FAKE_ARGS"'
check "元の場所への書き込みを禁じる" 'grep -Fxq "Edit(/$M/**)" "$FAKE_ARGS" && grep -Fxq "Edit(/$PDIR/**)" "$FAKE_ARGS" && grep -Fxq "Bash" "$FAKE_ARGS"'
check "--model を付けない" '! grep -Fxq -- "--model" "$FAKE_ARGS"'
rep="$(ls "$RDIR"/*.md | head -1)"
check "結果に件数と要点を書く" 'grep -q "自動で反映した追加: 1件" "$rep" && grep -q "承認待ちにした変更: 3件" "$rep" && grep -q "要点1" "$rep"'

echo "== 対象が変わっていなければ起動しない"
rm -f "$FAKE_ARGS"
"$RUN"
check "claude を起動しない" '[ ! -f "$FAKE_ARGS" ]'

echo "== 異常終了なら何も反映しない"
printf 'm2\nmore\n' >"$M/b.md"
before="$(cat "$M/b.md")"
n_before="$(ls "$PDIR" | wc -l)"
FAKE_RC=3 FAKE_HOOK='mkdir -p "$STAGE'"$S_M"'"; printf "m2\nmore\nadd\n" >"$STAGE'"$S_M"'/b.md"' "$RUN"
rc=$?
check "終了コードを返す" '[ "$rc" -eq 3 ]'
check "書き戻さない・案を作らない" '[ "$(cat "$M/b.md")" = "$before" ] && [ "$(ls "$PDIR" | wc -l)" = "$n_before" ]'

echo "== 上限5件"
for k in 1 2 3 4 5 6 7; do printf 'k\n' >"$M/k$k.md"; done
FAKE_HOOK='mkdir -p "$STAGE'"$S_M"'"; for k in 1 2 3 4 5 6 7; do printf "k\nadd\n" >"$STAGE'"$S_M"'/k$k.md"; done' "$RUN" --force
added="$(grep -l add "$M"/k*.md | wc -l | tr -d " ")"
check "書き戻しは5件まで" '[ "$added" = "5" ]'

echo "== 消える記述の行き先と、索引の行の削除"
NL=$'\n'
printf 'g1 決まり\ng2 経緯\n' >"$M/g.md"
printf 'h1\nh2\n' >"$M/h.md"
printf -- '- [G](g.md) — g\n- [A](a.md) — a\n' >"$M/MEMORY.md"
printf '# 規則\n\n- 既存\n' >"$HOME/.claude/CLAUDE.md"
ls "$PDIR"/*.md | sort >"$WORK/props-before"
D_G="/destinations$S_M/g.md"
D_H="/destinations$S_M/h.md"
HOOK_DEST='mkdir -p "$STAGE'"$S_M"'" "$STAGE'"$D_G"'" "$STAGE'"$D_H"'"
printf "%s\t%s\n" "'"$M"'/g.md" "CLAUDE.md へ移す" >"$STAGE/deletions.tsv"
printf -- "- [A](a.md) — a\n- [N](n.md) — n\n" >"$STAGE'"$S_M"'/MEMORY.md"
printf "h1\n" >"$STAGE'"$S_M"'/h.md"
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | g1 の決まり | 記載なし → この案で移す | 移し先 \`'"$HOME"'/.claude/CLAUDE.md\`（規則） |\n" >"$STAGE'"$D_G"'/table.md"
printf "# 規則\n\n- 既存\n- g1 の決まり\n" >"$STAGE'"$D_G"'/CLAUDE.md"
printf "%s\t%s\n" "'"$HOME"'/.claude/CLAUDE.md" "CLAUDE.md" >"$STAGE'"$D_G"'/moves.tsv"
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | h2 の事実 | 記載なし → この案で移す | （候補なし） |\n" >"$STAGE'"$D_H"'/table.md"'
FAKE_HOOK="$HOOK_DEST" "$RUN" --force
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "依頼文に行き先の表の書き方を含む" 'grep -Fq "| No | 消える記述 | 行き先 | 場所 |" "$FAKE_ARGS" && grep -Fq "索引（MEMORY.md）の行は消さない" "$FAKE_ARGS"'
new_props="$(ls "$PDIR"/*.md | sort | comm -13 "$WORK/props-before" -)"
check "承認待ちは2件だけ増える（索引だけの案を作らない）" '[ "$(printf "%s\n" "$new_props" | grep -c .)" = "2" ]'
p_g="$(grep -l "^  - $M/g.md\$" $new_props)"
p_h="$(grep -l "^  - $M/h.md\$" $new_props)"
check "索引の行の削除はメモリの削除の案に入る" '[ -f "$p_g" ] && grep -Fxq "  - $M/MEMORY.md" "$p_g" && grep -Fxq -- "-- [G](g.md) — g" "$p_g"'
check "索引への追加は書き戻し、削除の候補の行は残す" '[ "$(cat "$M/MEMORY.md")" = "- [G](g.md) — g${NL}- [A](a.md) — a${NL}- [N](n.md) — n" ]'
check "削除の案に行き先の表と移し先への追加の差分が入る" 'grep -Fxq "## 消える記述の行き先" "$p_g" && grep -Fq "| 1 | g1 の決まり | 記載なし → この案で移す |" "$p_g" && grep -Fxq -- "--- $HOME/.claude/CLAUDE.md" "$p_g" && grep -Fxq "+- g1 の決まり" "$p_g" && ! grep -Fq "移し先の確認が必要" "$p_g"'
check "移し先へは自動で書き足さない" '[ "$(cat "$HOME/.claude/CLAUDE.md")" = "# 規則${NL}${NL}- 既存" ]'
check "移し先の候補が無ければ見出しに確認の印を付ける" '[ -f "$p_h" ] && grep -q "^# h.md の修正（review-loop の棚卸し）（移し先の確認が必要）$" "$p_h" && grep -Fq "No 1: 移し先の候補が無い" "$p_h"'

echo "== 二重起動の防止"
mkdir "$STATE/lock"
"$RUN" --force 2>/dev/null
rc=$?
check "lock があれば終了コード1" '[ "$rc" -eq 1 ]'
rmdir "$STATE/lock"

echo "== 引数"
"$RUN" --nosuch 2>/dev/null
check "不明な引数は終了コード2" '[ $? -eq 2 ]'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
