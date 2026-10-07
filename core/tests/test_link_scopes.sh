#!/bin/bash
# スキルの置き場所の直下にあるリンクの先の実体を、4つの定期実行のスクリプトが許可・拒否の規則に足すことの検査。local が無い版では review-loop だけを検査する。
# HOME を一時ディレクトリに差し替え、--dry-run の出力だけを見る。claude は起動しない。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
# 公開版（local が無い版）では、local のスクリプトの検査を飛ばす。
HAS_LOCAL=0
[ -d "$REPO/local/skills" ] && HAS_LOCAL=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/link-scopes-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
unset CLAUDE_REPORTS_ROOT CLAUDE_REPORTS_STATE CLAUDE_REVIEW_PROPOSALS CLAUDE_REVIEW_STATE CLAUDE_REVIEW_LOOP_MODEL \
  CLAUDE_REVIEW_LOOP_EFFORT SKILL_AUDIT_ROOT SKILL_AUDIT_STATE MEMORY_AUDIT_TARGETS FEEDBACK_MINING_SOURCES
export CHANGE_REVIEW_SCRIPTS="$REPO/core/skills/change-review/scripts"
export SKILL_AUDIT_OWN_LINK_ROOTS="$WORK/own"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
# 出力の中で、単一引用符で囲んだ引数がちょうど何回現れるかを数える。
count_arg() { printf '%s\n' "$1" | tr ' ' '\n' | grep -Fxc -- "'$2'"; }

# 偽の HOME。~/.claude/skills と ~/.claude/CLAUDE.md は ~/.claude2 へのリンクにする（本物と同じ形）。
SK="$HOME/.claude2/skills"
mkdir -p "$SK/alpha" "$SK/synced/x" "$WORK/own/ownskill" "$WORK/ext/extskill" "$HOME/.local/bin" \
  "$HOME/.claude2/projects/p1/memory"
mkdir -p "$HOME/.claude"
ln -s ../.claude2/skills "$HOME/.claude/skills"
printf '# rules\n' >"$HOME/.claude2/CLAUDE.md"
ln -s ../.claude2/CLAUDE.md "$HOME/.claude/CLAUDE.md"
printf '# alpha\n' >"$SK/alpha/SKILL.md"
printf '# own\n' >"$WORK/own/ownskill/SKILL.md"
printf '# ext\n' >"$WORK/ext/extskill/SKILL.md"
ln -s "$WORK/own/ownskill" "$SK/ownskill"
ln -s "$WORK/ext/extskill" "$SK/extskill"
ln -s "$WORK/ext/extskill" "$SK/extskill2"
ln -s "$WORK/nosuch" "$SK/broken"
ln -s "$REPO/core/skills/change-review" "$SK/change-review"
printf 'm1\n' >"$HOME/.claude2/projects/p1/memory/a.md"
printf '{"type":"user"}\n' >"$HOME/.claude2/projects/p1/s.jsonl"
CR_REAL="$REPO/core/skills/change-review"
OWN="$WORK/own/ownskill"
EXT="$WORK/ext/extskill"
CMD_REAL="$HOME/.claude2/CLAUDE.md"

echo "== 共通の処理（link-scopes.sh）"
. "$CHANGE_REVIEW_SCRIPTS/link-scopes.sh"
reals="$(skill_link_reals)"
check "実体の一覧に自作・外部・change-review・置き場所の実体を含む" \
  'printf "%s\n" "$reals" | grep -Fxq "$OWN" && printf "%s\n" "$reals" | grep -Fxq "$EXT" && printf "%s\n" "$reals" | grep -Fxq "$CR_REAL" && printf "%s\n" "$reals" | grep -Fxq "$SK"'
check "実体の一覧に重複が無い" '[ -z "$(printf "%s\n" "$reals" | sort | uniq -d)" ]'
check "実体の無いリンクを含まない" '! printf "%s\n" "$reals" | grep -Fq "nosuch"'
check "path_and_real はリンクの実体も出す" '[ "$(path_and_real "$HOME/.claude/CLAUDE.md" | tail -n 1)" = "$CMD_REAL" ]'

# 4つのスクリプトに共通する検査。引数: <名前> <dry-run の出力> <終了コード>
common_checks() {
  local name="$1" out="$2" rc="$3" r
  check "$name: 終了コード0" '[ "$rc" -eq 0 ]'
  for r in "$OWN" "$EXT" "$CR_REAL"; do
    check "$name: 実体の Read を1回だけ含む: $r" '[ "$(count_arg "$out" "Read(/$r/**)")" -eq 1 ]'
  done
  check "$name: 実体の無いリンクの規則を含まない" '! printf "%s" "$out" | grep -Fq "nosuch"'
}

if [ "$HAS_LOCAL" -eq 1 ]; then
echo "== memory-audit"
out="$("$REPO/local/skills/memory-audit/scripts/run.sh" --dry-run 2>&1)"; rc=$?
common_checks memory-audit "$out" "$rc"
check "memory-audit: CLAUDE.md の実体の Edit を拒否する" '[ "$(count_arg "$out" "Edit(/$CMD_REAL)")" -ge 1 ]'
check "memory-audit: リンクの先の実体の Edit を拒否する" '[ "$(count_arg "$out" "Edit(/$OWN/**)")" -eq 1 ] && [ "$(count_arg "$out" "Edit(/$EXT/**)")" -eq 1 ]'

echo "== feedback-mining"
out="$("$REPO/local/skills/feedback-mining/scripts/run.sh" --dry-run 2>&1)"; rc=$?
common_checks feedback-mining "$out" "$rc"
check "feedback-mining: CLAUDE.md の実体の Edit を拒否する" '[ "$(count_arg "$out" "Edit(/$CMD_REAL)")" -ge 1 ]'

fi

echo "== review-loop"
out="$("$REPO/core/skills/review-loop/scripts/run.sh" --dry-run 2>&1)"; rc=$?
common_checks review-loop "$out" "$rc"
check "review-loop: リンクの先の実体の Edit を拒否する" '[ "$(count_arg "$out" "Edit(/$OWN/**)")" -eq 1 ]'

if [ "$HAS_LOCAL" -eq 1 ]; then
echo "== skill-audit"
out="$("$REPO/local/skills/skill-audit/scripts/run-audit.sh" --force --dry-run 2>&1)"; rc=$?
common_checks skill-audit "$out" "$rc"
allow_part="${out%%--disallowedTools*}"
deny_part="${out#*--disallowedTools}"
check "skill-audit: 自作のリンクの実体に Edit を許可する" '[ "$(count_arg "$allow_part" "Edit(/$OWN/**)")" -eq 1 ]'
check "skill-audit: 自作のリンクの実体の Edit を拒否しない" '[ "$(count_arg "$deny_part" "Edit(/$OWN/**)")" -eq 0 ]'
check "skill-audit: 外部のリンクの実体に Edit を許可しない" '[ "$(count_arg "$allow_part" "Edit(/$EXT/**)")" -eq 0 ]'
check "skill-audit: 外部のリンクの実体の Edit を1回だけ拒否する" '[ "$(count_arg "$deny_part" "Edit(/$EXT/**)")" -eq 1 ]'
check "skill-audit: change-review の実体に Edit を許可しない" '[ "$(count_arg "$allow_part" "Edit(/$CR_REAL/**)")" -eq 0 ]'
check "skill-audit: CLAUDE.md の実体の Edit を拒否する" '[ "$(count_arg "$deny_part" "Edit(/$CMD_REAL)")" -eq 1 ]'

echo "== skill-audit の対象の判定"
. "$REPO/local/skills/skill-audit/scripts/lib.sh"
check "自作のリンクは対象" 'is_target ownskill'
check "外部のリンク・実体の無いリンク・synced は対象外" '! is_target extskill && ! is_target broken && ! is_target synced'
check "trash-skill.sh はリンクのスキルを移動しない" '! "$REPO/local/skills/skill-audit/scripts/trash-skill.sh" ownskill >/dev/null 2>&1 && [ -L "$SK/ownskill" ]'

echo "== skill-audit: 自作のリンクの実体への修正は戻して承認待ちにする（偽の claude）"
cat >"$HOME/.local/bin/claude" <<EOF
#!/bin/bash
printf '# own changed\n' >"$OWN/SKILL.md"
printf 'added\n' >"$OWN/new.md"
exit 0
EOF
chmod +x "$HOME/.local/bin/claude"
"$REPO/local/skills/skill-audit/scripts/run-audit.sh" --force >/dev/null 2>&1; rc=$?
check "skill-audit: 終了コード0" '[ "$rc" -eq 0 ]'
check "skill-audit: 既存の行の修正は実行前の版に戻す" '[ "$(cat "$OWN/SKILL.md")" = "# own" ]'
check "skill-audit: 新しいファイルは残す" '[ -f "$OWN/new.md" ]'
check "skill-audit: 修正の承認待ちを作る" 'grep -lq "ownskill/SKILL.md" "$HOME/claude-reports/proposals/"*.md 2>/dev/null </dev/null'
check "skill-audit: リンクはリンクのまま残る" '[ -L "$SK/ownskill" ]'

else
  echo "== memory-audit・feedback-mining・skill-audit: local が無いため飛ばす"
fi

printf '\nRESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
