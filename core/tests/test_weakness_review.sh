#!/bin/bash
# requires: weakness-review
# weakness-review の scripts/run.sh の検査。一時の HOME と偽の claude で動かし、本物の HOME・claude には触れない。
# 材料が無いときに起動しないこと、前回の実行より後の記録だけを渡すこと、claude -p に記録・設定・会話の履歴を
# 書き換えさせない規則を渡すこと、成功したときだけ last-run を進めることを確かめる。
# change-review が無い書き出し先では、link-scopes.sh の代わりに最小の偽物を使う。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
RUN="$REPO/core/skills/weakness-review/scripts/run.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/weakness-review-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { if eval "$2"; then pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; else fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; fi; }

export HOME="$WORK/home"
mkdir -p "$HOME/.claude/skills"
unset XDG_CONFIG_HOME CLAUDE_REPORTS_ROOT CLAUDE_REPORTS_STATE WEAKNESS_REVIEW_LOG WEAKNESS_REVIEW_GATE_LOG \
  UI_TEXT_FEEDBACK_LOG SKILL_AUDIT_STATE CLAUDE_REVIEW_PROPOSALS CLAUDE_REVIEW_STATE CLAUDE_REVIEW_DENY_READ \
  AI_AGENTS_CONFIG_DIR CLAUDE_CONFIG_DIR
export CLAUDE_REVIEW_JOBS_CONF="$WORK/no-jobs.conf"
export CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude"

if [ -f "$REPO/core/skills/change-review/scripts/link-scopes.sh" ]; then
  export CHANGE_REVIEW_SCRIPTS="$REPO/core/skills/change-review/scripts"
else
  mkdir -p "$WORK/lsc"
  cat >"$WORK/lsc/link-scopes.sh" <<'EOF'
path_and_real() { printf '%s\n' "$1"; }
skill_link_reals() { return 0; }
guard_deny_rules() { printf 'Edit(/stub-guard)\n'; }
EOF
  export CHANGE_REVIEW_SCRIPTS="$WORK/lsc"
fi

# 偽の claude。受け取った引数を残し、FAKE_RC で終わる。FAKE_WRITE=1 なら依頼文の出力先に結果を書く。
FAKE="$WORK/fake-claude"
cat >"$FAKE" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_ARGS"
prompt=""
while [ "$#" -gt 0 ]; do
  [ "$1" = "-p" ] && { prompt="$2"; break; }
  shift
done
if [ "${FAKE_WRITE:-1}" = "1" ]; then
  out="$(printf '%s' "$prompt" | sed -n 's/.*結果の出力先は \([^。]*\)。.*/\1/p')"
  [ -n "$out" ] && printf '# 弱点の見直し\n' >"$out"
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FAKE"
export CLAUDE_LAUNCHER="$FAKE"
export FAKE_ARGS="$WORK/fake-args"

STATE="$HOME/.local/state/claude-reports/weakness-review"
REPORTS="$HOME/claude-reports/weakness-review"
LOG_MD="$STATE/log.md"
LAST="$STATE/last-run"
mtime() { stat -f '%m' "$1" 2>/dev/null; }
reports() { ls "$REPORTS"/*.md 2>/dev/null | wc -l | tr -d ' '; }
# ログは秒単位の名前なので、同じ秒の実行は同じファイルに足される。全部のログから探す。
in_logs() { cat "$STATE/logs/"*.log 2>/dev/null | grep -q "$1"; }

echo "== 材料が無いとき"
out="$("$RUN" --dry-run 2>&1)"; rc=$?
check "--dry-run: 終了コード0で起動しない" '[ "$rc" -eq 0 ] && printf "%s" "$out" | grep -q "材料なし。起動しません" && [ ! -e "$FAKE_ARGS" ]'
check "--dry-run: 結果も last-run も書かない" '[ "$(reports)" = 0 ] && [ ! -e "$LAST" ]'
"$RUN" >/dev/null 2>&1; rc=$?
check "本実行: 終了コード0で claude を起動しない" '[ "$rc" -eq 0 ] && [ ! -e "$FAKE_ARGS" ]'
check "本実行: 材料なしの結果を書き、last-run を作る" '[ "$(reports)" = 1 ] && grep -q "ありませんでした" "$REPORTS"/*.md && [ -f "$LAST" ]'
rm -f "$REPORTS"/*.md

echo "== 前回より後の記録だけを渡す"
mkdir -p "$STATE"
cat >"$LOG_MD" <<'EOF'
## 2025-12-31 23:00 ~/src/old
- 指摘: 古い指摘
## 2026-02-01 10:00 ~/src/new
- 指摘: 新しい指摘
EOF
touch -t 202601010000 "$LAST"
last_before="$(mtime "$LAST")"
out="$("$RUN" --dry-run 2>&1)"; rc=$?
entries="$(ls -1t "$STATE"/entries-*.md 2>/dev/null | head -1)"
check "--dry-run: 終了コード0" '[ "$rc" -eq 0 ]'
check "記録は1件と数える" 'printf "%s" "$out" | grep -q "対象の期間: 2026-01-01 00:00 以降。記録: 1件"'
check "取り出したファイルに新しい指摘だけがある" '[ -n "$entries" ] && grep -q "新しい指摘" "$entries" && ! grep -q "古い指摘" "$entries"'
check "--dry-run: claude を起動せず、last-run を進めない" '[ ! -e "$FAKE_ARGS" ] && [ "$(mtime "$LAST")" = "$last_before" ]'
check "依頼文に取り出したファイルと出力先を書く" 'printf "%s" "$out" | grep -Fq "今週の指摘の記録は ${entries}（1件）" && printf "%s" "$out" | grep -q "結果の出力先は $REPORTS/"'
check "結果の置き場所だけに書き込みを許す" 'printf "%s" "$out" | grep -Fq "'"'"'Edit(/$REPORTS/**)'"'"'"'
check "記録と状態の置き場所への書き込みを拒否する" 'printf "%s" "$out" | grep -Fq "'"'"'Edit(/$LOG_MD)'"'"'" && printf "%s" "$out" | grep -Fq "'"'"'Edit(/$STATE/**)'"'"'"'
check "設定ディレクトリへの書き込みを拒否する" 'printf "%s" "$out" | grep -Fq "'"'"'Edit(/$HOME/.claude/**)'"'"'"'
check "会話の履歴（jsonl）を読ませない" 'printf "%s" "$out" | grep -Fq "'"'"'Read(/$HOME/.claude/projects/**/*.jsonl)'"'"'"'
check "change-review の拒否の規則を足す" 'printf "%s" "$out" | grep -q "disallowedTools"'

echo "== 本実行（成功）"
"$RUN" >/dev/null 2>&1; rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "claude に -p で依頼文を渡す" '[ -f "$FAKE_ARGS" ] && grep -qx -- "-p" "$FAKE_ARGS"'
check "結果を書く" '[ "$(reports)" = 1 ]'
check "last-run を進める" '[ "$(mtime "$LAST")" != "$last_before" ]'
check "ログに完了を書く" 'in_logs "見直しが完了しました"'

echo "== 本実行（失敗）"
rm -f "$REPORTS"/*.md "$FAKE_ARGS"
touch -t 202601010000 "$LAST"
FAKE_RC=3 "$RUN" >/dev/null 2>&1; rc=$?
check "claude の終了コードを返し、last-run を進めない" '[ "$rc" -eq 3 ] && [ "$(mtime "$LAST")" = "$last_before" ]'
sleep 1
FAKE_WRITE=0 "$RUN" >/dev/null 2>&1; rc=$?
check "結果が作られなければ終了コード1で、last-run を進めない" '[ "$rc" -eq 1 ] && [ "$(mtime "$LAST")" = "$last_before" ] && in_logs "レポートが作られていません"'

echo "== 引数と同時実行"
"$RUN" --unknown >/dev/null 2>&1; rc=$?
check "不明な引数は終了コード2" '[ "$rc" -eq 2 ]'
mkdir -p "$STATE/lock"
out="$("$RUN" --dry-run 2>&1)"; rc=$?
check "実行中（lock がある）なら終了コード1" '[ "$rc" -eq 1 ] && printf "%s" "$out" | grep -q "別の実行が進行中です"'
rmdir "$STATE/lock"

printf '\nRESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
