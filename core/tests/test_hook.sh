#!/bin/bash
# core/hooks/session-start.sh の検査。一時フォルダを案の置き場所にして実行する。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$TESTS_DIR/../hooks/session-start.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-hook-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_REVIEW_PROPOSALS="$WORK/proposals"
unset CLAUDE_REVIEW_PORT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
put() { printf -- '---\nid: %s\nstatus: %s\n---\n\n# x\n' "$1" "$2" >"$CLAUDE_REVIEW_PROPOSALS/$1-x.md"; }

out="$("$HOOK" 2>&1)"; rc=$?
check "置き場所が無ければ何も出さない" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
mkdir -p "$CLAUDE_REVIEW_PROPOSALS"
put 2026-10-05-01 applied
put 2026-10-05-02 rejected
out="$("$HOOK" 2>&1)"
check "0件なら何も出さない" '[ -z "$out" ]'
put 2026-10-05-03 pending
put 2026-10-05-04 pending
out="$("$HOOK")"
check "承認待ちだけ（出力: ${out}）" '[ "$out" = "承認待ち 2件（http://127.0.0.1:8010/）" ]'
put 2026-10-05-05 approved
out="$(CLAUDE_REVIEW_PORT=8123 "$HOOK")"
check "両方とポートの差し替え（出力: ${out}）" '[ "$out" = "承認待ち 2件・承認済み・未反映 1件（http://127.0.0.1:8123/）" ]'
rm "$CLAUDE_REVIEW_PROPOSALS"/2026-10-05-0[34]-x.md
out="$("$HOOK")"
check "承認済み・未反映だけ（出力: ${out}）" '[ "$out" = "承認済み・未反映 1件（http://127.0.0.1:8010/）" ]'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
