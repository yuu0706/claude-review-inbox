#!/bin/bash
# feedback-mining scripts の検査。一時ディレクトリに偽の会話の履歴を作って実行する。実際の claude は起動しない。
set -u
# 2つ目の設定ディレクトリの名前。利用者の環境の名前を書かないよう、中立な名前を変数で持つ。
ALT_DIR=.claude_alt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/feedback-mining-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
# 本物の HOME の下のスキル・案の置き場所・状態を探さないよう、HOME を一時ディレクトリにする。
export HOME="$WORK/home"
mkdir -p "$HOME/.claude" "$HOME/${ALT_DIR}"

export CLAUDE_REPORTS_ROOT="$WORK/reports"
export CLAUDE_REPORTS_STATE="$WORK/state"
export FEEDBACK_MINING_SOURCES="$WORK/p1:$WORK/p2:$WORK/missing"
unset CLAUDE_REVIEW_PROPOSALS CLAUDE_REVIEW_STATE SKILL_AUDIT_STATE XDG_CONFIG_HOME CLAUDE_REVIEW_DENY_READ
# 起動するコマンドは常に偽物にする（本物の claude を起動しない）。共通の設定ファイルは一時の場所を指す。
export CLAUDE_LAUNCHER="$WORK/fake-claude"
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
export CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude:$HOME/${ALT_DIR}"
PDIR="$CLAUDE_REPORTS_ROOT/proposals"
LEDGER="$HOME/.local/state/claude-review-inbox"
STATE="$CLAUDE_REPORTS_STATE/feedback-mining"
RDIR="$CLAUDE_REPORTS_ROOT/feedback-mining"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 依頼文からレポートの出力先を取り出して書き込む偽の claude。受け取った引数も記録する。
FAKE="$WORK/fake-claude"
cat >"$FAKE" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_ARGS"
while [ $# -gt 0 ]; do
  if [ "$1" = "-p" ]; then
    out="${2##*レポートの出力先は }"
    out="${out%%。*}"
    printf '# 指摘の収集レポート\n\n検査用\n' >"$out"
  fi
  shift
done
exit 0
EOF
chmod +x "$FAKE"
export FAKE_ARGS="$WORK/fake-args"

line() { printf '{"type":"user","entrypoint":"%s","message":{"content":"x"}}\n' "$1"; }
mkdir -p "$WORK/p1/proj-a/sess-1/subagents" "$WORK/p2/proj-b"
{ printf '{"type":"summary"}\n'; line cli; } >"$WORK/p1/proj-a/human-cli.jsonl"
line claude-vscode >"$WORK/p1/proj-a/human-vscode.jsonl"
{ line sdk-cli; line cli; } >"$WORK/p1/proj-a/auto-print.jsonl"
line cli >"$WORK/p1/proj-a/sess-1/subagents/agent-1.jsonl"
line sdk-cli >"$WORK/p1/proj-a/sess-1/subagents/agent-auto.jsonl"
printf '{"type":"summary"}\n' >"$WORK/p2/proj-b/no-entrypoint.jsonl"
line cli >"$WORK/p2/proj-b/old.jsonl"
touch -t 200001010000 "$WORK/p2/proj-b/old.jsonl"
echo x >"$WORK/p1/proj-a/not-jsonl.txt"

latest_inputs() { ls -1t "$STATE/"inputs-*.txt 2>/dev/null | head -1; }

echo "== --dry-run（初回は過去7日）"
out="$("$SCRIPT_DIR/run.sh" --dry-run)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
inp="$(latest_inputs)"
check "inputs が状態ディレクトリに作られる" '[ -f "$inp" ]'
cat "$inp"
inhas() { grep -Fxq -- "$1" "$inp"; }
check "対話の CLI を含む" 'inhas "$WORK/p1/proj-a/human-cli.jsonl"'
check "VS Code を含む" 'inhas "$WORK/p1/proj-a/human-vscode.jsonl"'
check "subagents 配下を含む" 'inhas "$WORK/p1/proj-a/sess-1/subagents/agent-1.jsonl"'
check "entrypoint の無いファイルを含む" 'inhas "$WORK/p2/proj-b/no-entrypoint.jsonl"'
check "-p のセッションを除く" '! inhas "$WORK/p1/proj-a/auto-print.jsonl" && ! inhas "$WORK/p1/proj-a/sess-1/subagents/agent-auto.jsonl"'
check "7日より古いものを除く" '! inhas "$WORK/p2/proj-b/old.jsonl"'
check "jsonl 以外を除く" '! grep -q "not-jsonl" "$inp"'
check "件数は4件" '[ "$(wc -l <"$inp" | tr -d " ")" = "4" ]'
has() { printf '%s' "$out" | grep -Fq -- "$1"; }
day="$(date '+%Y-%m-%d')"
for rule in "'$FAKE' '-p'" \
  "Skill feedback-mining を自動モードで実行する。対象の会話の一覧は ${inp}、レポートの出力先は ${RDIR}/${day}.md。" \
  "否認リストは $PDIR/rejections.md にある。決まりの案を作る前に読み、否認リストと同じ対象・同じ趣旨の案は作らない。" \
  "'--model' 'opus' '--effort' 'low'" "'--allowedTools' 'Skill' 'Read(/$HOME/.claude/**)'" \
  "'Read(/$PDIR/**)' 'Read(/$HOME/.config/claude-skills/feedback-mining.local.md)' 'Read(/$HOME/.local/state/skill-audit/history.md)' 'Edit(/$RDIR/**)' '--disallowedTools'" \
  "'Read(/$HOME/.claude/**)' 'Read(/$HOME/${ALT_DIR}/**)'" \
  "'Read(/$HOME/.config/claude-skills/feedback-mining.local.md)'" \
  "利用者の環境だけの決まりは $HOME/.config/claude-skills/feedback-mining.local.md にある（無ければ飛ばす）。" \
  "'Read(/$HOME/Library/CloudStorage/**)' 'Edit(/$HOME/.claude/**)' 'Edit(/$HOME/${ALT_DIR}/**)' 'Edit(/$HOME/Documents/**)' 'Edit(/$HOME/.agents/**)'" \
  "'Edit(/$PDIR/**)' 'Edit(/$LEDGER/**)'" \
  "cd '$RDIR' &&"; do
  check "dry-run の出力に含む: $rule" 'has "$rule"'
done
allow_part="${out%%--disallowedTools*}"
check "許可側に範囲を付けない Read と任意のパスを読める Bash を含まない" '! printf "%s" "$allow_part" | grep -Fq "'"'"'Read'"'"'" && ! printf "%s" "$allow_part" | grep -q "Bash("'
check "許可側に承認待ちの置き場所と台帳の Edit を含まない" '! printf "%s" "$allow_part" | grep -Fq "Edit(/$PDIR" && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$LEDGER"'
check "許可に rm・mv・Write を含まない" '! has "Bash(rm" && ! has "Bash(mv" && ! has "Write"'
check "dry-run は last-run を作らない" '[ ! -f "$STATE/last-run" ]'
check "dry-run はレポートを作らない" '[ -z "$(ls "$RDIR")" ]'
check "dry-run はログを作らない" '[ -z "$(ls "$STATE/logs")" ]'
check "lock が解放されている" '[ ! -d "$STATE/lock" ]'

echo "== 通常実行（偽の claude）"
sleep 1
"$SCRIPT_DIR/run.sh"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "レポートが作られる" '[ -s "$RDIR/$day.md" ]'
check "last-run が作られる" '[ -f "$STATE/last-run" ]'
check "CLAUDE_LAUNCHER のコマンドに引数が渡る" 'grep -Fxq -- "--disallowedTools" "$FAKE_ARGS" && grep -Fxq -- "opus" "$FAKE_ARGS"'
check "開始時刻の一時ファイルが残らない" '[ -z "$(ls "$STATE/"run-started.* 2>/dev/null)" ]'
log1="$(ls -1t "$STATE/logs/"*.log | head -1)"
check "ログに完了が書かれる" 'grep -q "last-run を更新しました" "$log1"'

echo "== 2回目: 前回より後に更新されたものだけ"
sleep 1
line cli >>"$WORK/p1/proj-a/human-cli.jsonl"
"$SCRIPT_DIR/run.sh"
inp="$(latest_inputs)"
check "更新された1件だけが対象" '[ "$(cat "$inp")" = "$WORK/p1/proj-a/human-cli.jsonl" ]'
check "同日2回目は連番のレポート" '[ -s "$RDIR/$day-2.md" ]'

echo "== 対象0件"
sleep 1
before="$(stat -f %m "$STATE/last-run")"
sleep 1
rm -f "$FAKE_ARGS"
"$SCRIPT_DIR/run.sh"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "claude を起動しない" '[ ! -f "$FAKE_ARGS" ]'
check "「対象の会話なし」とだけ書いたレポート" 'grep -Fxq "対象の会話なし" "$RDIR/$day-3.md" && [ "$(grep -c . "$RDIR/$day-3.md")" = "2" ]'
check "inputs は空で残る" '[ -f "$(latest_inputs)" ] && [ ! -s "$(latest_inputs)" ]'

echo "== 異常終了時は last-run を更新しない"
sleep 1
line cli >>"$WORK/p1/proj-a/human-vscode.jsonl"
before="$(stat -f %m "$STATE/last-run")"
CLAUDE_LAUNCHER=false "$SCRIPT_DIR/run.sh"
rc=$?
check "非0で last-run 据え置き（rc=${rc}）" '[ "$rc" -ne 0 ] && [ "$(stat -f %m "$STATE/last-run")" = "$before" ]'
CLAUDE_LAUNCHER=true "$SCRIPT_DIR/run.sh"
rc=$?
check "レポートが作られなければ非0で last-run 据え置き（rc=${rc}）" '[ "$rc" -ne 0 ] && [ "$(stat -f %m "$STATE/last-run")" = "$before" ]'
check "lock が解放されている" '[ ! -d "$STATE/lock" ]'

echo "== 二重起動の拒否"
mkdir "$STATE/lock"
"$SCRIPT_DIR/run.sh" --dry-run >/dev/null 2>&1
rc=$?
check "lock があれば終了コード1" '[ "$rc" -eq 1 ]'
check "他者の lock を消さない" '[ -d "$STATE/lock" ]'
rmdir "$STATE/lock"

echo "== ログの保持件数"
for i in $(seq 1 40); do touch -t "200001010000.$(printf '%02d' $((i % 60)))" "$STATE/logs/old-$i.log"; done
"$SCRIPT_DIR/run.sh"
n="$(ls "$STATE/logs/"*.log | wc -l | tr -d ' ')"
check "ログは30件以下（実際: ${n}）" '[ "$n" -le 30 ]'

echo "== 起動するコマンドと設定ディレクトリの指定"
touch "$WORK/p1/proj-a/human-cli.jsonl"
out="$(CLAUDE_LAUNCHER="/opt/launcher {job} --flag" "$SCRIPT_DIR/run.sh" --dry-run)"
check "{job} をジョブ名に置き換え、語ごとに渡す" 'printf "%s" "$out" | grep -Fq "&& '"'"'/opt/launcher'"'"' '"'"'feedback-mining'"'"' '"'"'--flag'"'"' '"'"'-p'"'"'"'
printf 'CLAUDE_LAUNCHER=~/bin/launcher {job}\nCLAUDE_REVIEW_CONFIG_DIRS=~/.claude\nCLAUDE_REVIEW_DENY_READ=~/sync-a\n' >"$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u CLAUDE_LAUNCHER -u CLAUDE_REVIEW_CONFIG_DIRS "$SCRIPT_DIR/run.sh" --dry-run)"
check "設定ファイルの起動コマンドを使い、~ を展開する" 'printf "%s" "$out" | grep -Fq "&& '"'"'$HOME/bin/launcher'"'"' '"'"'feedback-mining'"'"' '"'"'-p'"'"'"'
check "設定ファイルの設定ディレクトリだけを使う" '! printf "%s" "$out" | grep -Fq "${ALT_DIR}"'
check "設定ファイルの読み取りの拒否を足す" 'printf "%s" "$out" | grep -Fq "'"'"'Read(/$HOME/sync-a/**)'"'"'"'
out="$(CLAUDE_LAUNCHER=/opt/env-launcher "$SCRIPT_DIR/run.sh" --dry-run)"
check "環境変数が設定ファイルより優先する" 'printf "%s" "$out" | grep -Fq "&& '"'"'/opt/env-launcher'"'"' '"'"'-p'"'"'"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
mkdir -p "$HOME/.claude/projects/proj-x"
line cli >"$HOME/.claude/projects/proj-x/s.jsonl"
out="$(env -u FEEDBACK_MINING_SOURCES "$SCRIPT_DIR/run.sh" --dry-run)"
check "会話の履歴の既定は設定ディレクトリの projects" 'grep -Fxq "$HOME/.claude/projects/proj-x/s.jsonl" "$(latest_inputs)"'

echo "== 指定が無い場合"
mkdir -p "$HOME/.local/bin"
ln -sfn "$FAKE" "$HOME/.local/bin/claude"
sleep 1
touch "$WORK/p1/proj-a/human-cli.jsonl"
rm -f "$FAKE_ARGS"
env -u CLAUDE_LAUNCHER "$SCRIPT_DIR/run.sh"
log1="$(ls -1t "$STATE/logs/"*.log | head -1)"
check "claude を起動する" 'grep -Fxq -- "-p" "$FAKE_ARGS" && grep -Fxq -- "--disallowedTools" "$FAKE_ARGS"'
check "起動に使うコマンドをログに書く" 'grep -q "起動に使うコマンド: claude$" "$log1"'
check "claude をコマンドとして組み立てる" 'grep -Fq "&& '"'"'claude'"'"' '"'"'-p'"'"'" "$log1"'

echo "== plist のひな形"
PL="$WORK/feedback-mining.plist"
sed -e "s|@@LABEL@@|com.example.feedback-mining|g" -e "s|@@SCRIPT@@|/path/to/run.sh|g" -e "s|@@HOME@@|$WORK/home|g" \
  "$SCRIPT_DIR/../launchd/feedback-mining.plist.template" >"$PL"
plutil -lint "$PL"
rc=$?
check "plutil -lint が通る" '[ "$rc" -eq 0 ]'
check "毎週月曜 11:00" '[ "$(plutil -extract StartCalendarInterval.Weekday raw "$PL")" = "1" ] && [ "$(plutil -extract StartCalendarInterval.Hour raw "$PL")" = "11" ] && [ "$(plutil -extract StartCalendarInterval.Minute raw "$PL")" = "0" ]'

echo "== 実行権限"
for f in run.sh test.sh; do
  check "実行権限: $f" '[ -x "$SCRIPT_DIR/$f" ]'
done

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
