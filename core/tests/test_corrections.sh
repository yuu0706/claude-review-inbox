#!/bin/bash
# requires: change-review
# change-review の corrections.sh（訂正リスト）の検査。置き場所は一時ディレクトリにする。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CS="$TESTS_DIR/../skills/change-review/scripts/corrections.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/corrections-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_REVIEW_PROPOSALS="$WORK/proposals"
F="$CLAUDE_REVIEW_PROPOSALS/corrections.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

check "置き場所は否認リストの隣" '[ "$(bash "$CS" path)" = "$F" ]'
check "訂正リストが無ければ 0 件" '[ "$(bash "$CS" count skill-audit/修正/beta)" = "0" ]'

out="$(bash "$CS" add --id skill-audit-2026-10-16-100000-01 --kind skill-audit/修正/beta --target /x/beta/SKILL.md --correct "正しくは手順 2 を残す" --date 2026-10-16)"
check "足すと訂正リストのパスを出す" '[ "$out" = "$F" ]'
check "初回は冒頭の説明と表の見出しを作る" '[ "$(head -1 "$F")" = "# 訂正リスト" ] && grep -Fxq "| 変更の ID | 種類 | 対象 | 正しくは | 訂正日 |" "$F"'
check "1行1件で書く" 'grep -Fxq "| skill-audit-2026-10-16-100000-01 | skill-audit/修正/beta | /x/beta/SKILL.md | 正しくは手順 2 を残す | 2026-10-16 |" "$F"'
check "同じ種類を数える" '[ "$(bash "$CS" count skill-audit/修正/beta)" = "1" ]'

bash "$CS" add --id skill-audit-2026-10-23-100000-02 --kind skill-audit/修正/beta --target /x/beta/SKILL.md --correct "正しくは a|b の両方を残す" >/dev/null
bash "$CS" add --id memory-audit-2026-10-23-100000-01 --kind memory-audit/削除/proj-a/d.md --target /x/d.md --correct "正しくは d.md を残す" >/dev/null
check "2回目で 2 件になる" '[ "$(bash "$CS" count skill-audit/修正/beta)" = "2" ]'
check "別の種類は数えない" '[ "$(bash "$CS" count skill-audit/削除/beta)" = "0" ] && [ "$(bash "$CS" count memory-audit/削除/proj-a/d.md)" = "1" ]'
check "セルの中の | は \\| にする" 'grep -Fq "正しくは a\\|b の両方を残す" "$F"'
check "冒頭の説明は1回だけ" '[ "$(grep -c "^# 訂正リスト" "$F")" = "1" ]'

bash "$CS" add --id x --kind y >/dev/null 2>&1
check "必須の引数が無ければ終了コード2" '[ $? -eq 2 ]'
bash "$CS" count >/dev/null 2>&1
check "種類が無ければ終了コード2" '[ $? -eq 2 ]'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
