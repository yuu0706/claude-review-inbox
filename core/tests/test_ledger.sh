#!/bin/bash
# 変更の台帳（change-review の ledger.sh・revert.sh）と、会話の開始時の知らせ（report-inbox の unread.sh）の検査。
# HOME と台帳の置き場所を一時ディレクトリにする。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ledger-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME"
unset CLAUDE_REVIEW_PROPOSALS XDG_CONFIG_HOME
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
export CLAUDE_CHANGE_LEDGER="$WORK/ledger"
export CLAUDE_REPORTS_ROOT="$WORK/reports"
export CLAUDE_REPORTS_STATE="$WORK/state"
export SKILL_AUDIT_STATE="$WORK/skill-audit-state"
CR="$REPO/core/skills/change-review/scripts"
export CHANGE_REVIEW_SCRIPTS="$CR"
L="$CLAUDE_CHANGE_LEDGER"
NL=$'\n'

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

echo "== 置き場所"
check "path は CLAUDE_CHANGE_LEDGER" '[ "$(bash "$CR/ledger.sh" path)" = "$L" ]'
printf 'CLAUDE_CHANGE_LEDGER=~/ledger-from-conf\n' >"$CLAUDE_REVIEW_JOBS_CONF"
check "jobs.conf の指定を読み、~ を展開する" '[ "$(env -u CLAUDE_CHANGE_LEDGER bash "$CR/ledger.sh" path)" = "$HOME/ledger-from-conf" ]'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"

echo "== 記録"
T="$HOME/mem/a.md"
mkdir -p "$HOME/mem"
printf 'before\n' >"$WORK/a.before"
printf 'after\n' >"$T"
bash "$CR/ledger.sh" record --id memory-audit-2026-10-16-100000-01 --kind memory-audit/修正/p/a.md --target "$T" --before "$WORK/a.before" >/dev/null
rc=$?
check "終了コード0で、台帳が無ければ git init する" '[ "$rc" -eq 0 ] && [ -d "$L/.git" ]'
check "直す前と直した後の版を写す" '[ "$(cat "$L/entries/memory-audit-2026-10-16-100000-01/1/before")" = "before" ] && [ "$(cat "$L/entries/memory-audit-2026-10-16-100000-01/1/after")" = "after" ]'
check "コミットのメッセージに ID・種類・対象を入れる" '[ "$(git -C "$L" log -1 --format=%s)" = "record: memory-audit-2026-10-16-100000-01 memory-audit/修正/p/a.md $T" ]'
N="$HOME/skills/x/new.md"
mkdir -p "${N%/*}"
printf 'new\n' >"$N"
bash "$CR/ledger.sh" record --id skill-audit-2026-10-16-100000-01 --kind skill-audit/追加/x --target "$N" --before - >/dev/null
check "追加は直す前の版を置かない" '[ ! -e "$L/entries/skill-audit-2026-10-16-100000-01/1/before" ] && [ -f "$L/entries/skill-audit-2026-10-16-100000-01/1/after" ]'
D="$HOME/skills/gone"
mkdir -p "$WORK/gone-before/ref"
printf 'gone\n' >"$WORK/gone-before/SKILL.md"
printf 'ref\n' >"$WORK/gone-before/ref/a.md"
bash "$CR/ledger.sh" record --id skill-audit-2026-10-16-100000-02 --kind skill-audit/削除/gone --target "$D" --before "$WORK/gone-before" --after - >/dev/null
check "スキルの削除はフォルダごと写す" '[ -f "$L/entries/skill-audit-2026-10-16-100000-02/1/before/ref/a.md" ]'
for bad in "../x" ".hidden" "a/b" "" "a b"; do
  bash "$CR/ledger.sh" record --id "$bad" --kind k --target "$T" --before - >/dev/null 2>&1
  rc=$?
  check "正しくない ID を拒否する: '$bad'" '[ "$rc" -eq 2 ]'
done
bash "$CR/ledger.sh" record --id ok-1 --kind k --target relative/path --before - >/dev/null 2>&1
rc=$?
check "相対パスの対象を拒否する" '[ "$rc" -eq 2 ]'
TAB=$'\t'
check "show は種類と対象を出す" '[ "$(bash "$CR/ledger.sh" show memory-audit-2026-10-16-100000-01)" = "memory-audit/修正/p/a.md${TAB}$T" ]'

echo "== 会話の開始時の知らせ（unread.sh）"
mkdir -p "$CLAUDE_REPORTS_ROOT"
out="$("$REPO/core/skills/report-inbox/scripts/unread.sh")"
check "前回の会話以降に自動で反映した変更の件数と ID を出す" '[ "$out" = "前回の会話以降に自動で反映した変更 3件（memory-audit-2026-10-16-100000-01、skill-audit-2026-10-16-100000-01、skill-audit-2026-10-16-100000-02。戻すときは「<ID> を戻して」）" ]'
out="$("$REPO/core/skills/report-inbox/scripts/unread.sh")"
check "2回目は出さない（印を進める）" '[ -z "$out" ]'
for i in 03 04 05 06; do
  bash "$CR/ledger.sh" record --id "skill-audit-2026-10-16-100000-$i" --kind skill-audit/追加/x --target "$HOME/skills/x/f$i.md" --before - --after - >/dev/null
done
out="$("$REPO/core/skills/report-inbox/scripts/unread.sh")"
check "4件以上は3件だけ ID を並べる" 'printf "%s" "$out" | grep -Fq "自動で反映した変更 4件（skill-audit-2026-10-16-100000-03、skill-audit-2026-10-16-100000-04、skill-audit-2026-10-16-100000-05 ほか。"'
bash "$CR/ledger.sh" record --id skill-audit-2026-10-16-100000-07 --kind skill-audit/追加/x --target "$HOME/skills/x/f07.md" --before - --after - >/dev/null
"$REPO/core/skills/report-inbox/scripts/unread.sh" >&-
out="$("$REPO/core/skills/report-inbox/scripts/unread.sh")"
check "表示に失敗したら印を進めず、次の会話で出す" 'printf "%s" "$out" | grep -Fq "自動で反映した変更 1件（skill-audit-2026-10-16-100000-07。"'
out="$("$REPO/core/skills/report-inbox/scripts/unread.sh")"
check "表示できたら印を進める" '[ -z "$out" ]'
out="$(CLAUDE_CHANGE_LEDGER="$WORK/no-ledger""$REPO/core/skills/report-inbox/scripts/unread.sh")"
check "台帳が無ければ何も出さない" '[ -z "$out" ] && [ ! -e "$WORK/no-ledger" ]'

echo "== 戻す"
out="$(bash "$CR/revert.sh" memory-audit-2026-10-16-100000-01 2>&1)"; rc=$?
check "修正を直す前の版へ戻す" '[ "$rc" -eq 0 ] && [ "$(cat "$T")" = "before" ]'
check "戻す前の内容を台帳の removed に残す" '[ "$(cat "$L/entries/memory-audit-2026-10-16-100000-01/1/removed")" = "after" ]'
check "戻したことをコミットする" '[ "$(git -C "$L" log -1 --format=%s)" = "revert: memory-audit-2026-10-16-100000-01" ] && [ -z "$(git -C "$L" status --porcelain)" ]'
check "訂正リストへの追記を促す" 'printf "%s" "$out" | grep -Fq "corrections.sh add --id memory-audit-2026-10-16-100000-01 --kind memory-audit/修正/p/a.md --target $T --correct"'
out="$("$REPO/core/skills/report-inbox/scripts/unread.sh")"
check "戻したコミットは自動で反映した変更に数えない" '[ -z "$out" ]'
bash "$CR/revert.sh" memory-audit-2026-10-16-100000-01 >/dev/null 2>&1
rc=$?
check "同じ ID を2回は戻さない" '[ "$rc" -ne 0 ] && [ "$(cat "$T")" = "before" ]'
bash "$CR/revert.sh" skill-audit-2026-10-16-100000-01 >/dev/null 2>&1
check "追加を戻すとファイルが無くなる（台帳の removed に残る）" '[ ! -e "$N" ] && [ "$(cat "$L/entries/skill-audit-2026-10-16-100000-01/1/removed")" = "new" ]'
bash "$CR/revert.sh" skill-audit-2026-10-16-100000-02 >/dev/null 2>&1
check "スキルの削除を戻すとフォルダごと戻る" '[ "$(cat "$D/SKILL.md")" = "gone" ] && [ "$(cat "$D/ref/a.md")" = "ref" ]'
bash "$CR/revert.sh" no-such-id >/dev/null 2>&1
rc=$?
check "台帳に無い ID は終了コード1" '[ "$rc" -eq 1 ]'
bash "$CR/revert.sh" >/dev/null 2>&1
rc=$?
check "ID が無ければ終了コード2" '[ "$rc" -eq 2 ]'

printf '\nRESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
