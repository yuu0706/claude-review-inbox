#!/bin/bash
# claude-review-inbox の検査をすべて動かす。本物の HOME・launchctl・brew には触れない。
# 使い方: core/tests/run.sh [--core-only]
#   --core-only  tools/test_export_public.sh を動かさない（公開版の書き出しの中で、書き出した版を検査するときに使う）
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
PYTHON="${CLAUDE_REVIEW_PYTHON:-/usr/bin/python3}"
core_only=0
[ "${1:-}" = "--core-only" ] && core_only=1

results=()
failed=0
# テストの頭の「# requires: <スキル名> ...」のスキルが core/skills に無ければ飛ばす。
# 公開版は組ごとに一部のスキルだけを持つため（2026-11-04）。
missing_skills() {
  local f="$1" r out=""
  for r in $(sed -n 's/^# requires: //p' "$f" | head -n 1); do
    [ -d "$REPO/core/skills/$r" ] || out="${out:+$out }$r"
  done
  printf '%s' "$out"
}
run_test() {
  local name="$1" rc miss f
  shift
  for f in "$@"; do
    case "$f" in */test_*.sh|*/test_*.py|*/scripts/test.sh)
      miss="$(missing_skills "$f")"
      if [ -n "$miss" ]; then
        results+=("SKIP ${name}（無いスキル: ${miss}）")
        return 0
      fi ;;
    esac
  done
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

run_test "core: 直したいことの記録" "$PYTHON" -B "$TESTS_DIR/test_changes.py"
run_test "core: install.sh" bash "$TESTS_DIR/test_install.sh"
run_test "core: install.sh の定期実行" bash "$TESTS_DIR/test_install_schedule.sh"
run_test "core: install.sh の必要なものの確認" bash "$TESTS_DIR/test_install_prereq.sh"
run_test "core: install.sh の組ごとの入れ・外し" bash "$TESTS_DIR/test_install_groups.sh"
run_test "core: リンクの先の実体の許可と拒否" bash "$TESTS_DIR/test_link_scopes.sh"
run_test "core: 消える記述の行き先" bash "$TESTS_DIR/test_destinations.sh"
run_test "core: 訂正リスト" bash "$TESTS_DIR/test_corrections.sh"
run_test "core: 書き換えを拒否する規則（南京錠）" bash "$TESTS_DIR/test_guard_rules.sh"
run_test "core: 変更の台帳と会話の開始時の知らせ" bash "$TESTS_DIR/test_ledger.sh"
run_test "core: 弱点の見直しの起動" bash "$TESTS_DIR/test_weakness_review.sh"
[ -f "$REPO/core/skills/memory-audit/scripts/test-tag.sh" ] &&
  run_test "skill: memory-audit の作成したリポジトリの記録" bash "$REPO/core/skills/memory-audit/scripts/test-tag.sh"
for t in "$REPO"/core/skills/*/scripts/test.sh; do
  [ -f "$t" ] || continue
  s="${t%/scripts/test.sh}"
  run_test "skill: ${s##*/}" bash "$t"
done
# 公開版の書き出しの検査は全部入りにだけある。
if [ "$core_only" -eq 0 ] && [ -f "$REPO/tools/test_export_public.sh" ]; then
  run_test "tools: 公開版の書き出し" bash "$REPO/tools/test_export_public.sh"
fi

printf '\n==== 結果\n'
for r in "${results[@]}"; do printf '%s\n' "$r"; done
exit "$failed"
