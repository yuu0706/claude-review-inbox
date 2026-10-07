#!/bin/bash
# claude-review-inbox の検査をすべて動かす。本物の HOME・launchctl・brew には触れない。
# 使い方: core/tests/run.sh [--core-only]
#   --core-only  local/skills/*/scripts/test.sh と tools/test_export_public.sh を動かさない
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
PYTHON="${CLAUDE_REVIEW_PYTHON:-/usr/bin/python3}"
core_only=0
[ "${1:-}" = "--core-only" ] && core_only=1

results=()
failed=0
run_test() {
  local name="$1" rc
  shift
  printf '\n==== %s\n' "$name"
  "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    results+=("OK   $name")
  else
    results+=("FAIL ${name}（終了コード ${rc}）")
    failed=1
  fi
}

run_test "core: 承認済みの判定・集計・案の作成" "$PYTHON" "$TESTS_DIR/test_approved.py"
run_test "core: サーバー" "$PYTHON" "$TESTS_DIR/test_server.py"
run_test "core: SessionStart フック" bash "$TESTS_DIR/test_hook.sh"
run_test "core: install.sh" bash "$TESTS_DIR/test_install.sh"
run_test "core: install.sh の定期実行" bash "$TESTS_DIR/test_install_schedule.sh"
run_test "core: 週1回の棚卸し（review-loop）" bash "$TESTS_DIR/test_review_loop.sh"
run_test "core: リンクの先の実体の許可と拒否" bash "$TESTS_DIR/test_link_scopes.sh"
run_test "core: 消える記述の行き先" bash "$TESTS_DIR/test_destinations.sh"
if [ "$core_only" -eq 0 ]; then
  # 公開版の書き出しの検査は全部入りにだけある。
  if [ -f "$REPO/tools/test_export_public.sh" ]; then
    run_test "tools: 公開版の書き出し" bash "$REPO/tools/test_export_public.sh"
  fi
  for t in "$REPO"/local/skills/*/scripts/test.sh; do
    [ -f "$t" ] || continue
    s="${t%/scripts/test.sh}"
    run_test "local: ${s##*/}" bash "$t"
  done
fi

printf '\n==== 結果\n'
for r in "${results[@]}"; do printf '%s\n' "$r"; done
exit "$failed"
