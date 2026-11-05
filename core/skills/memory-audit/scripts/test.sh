#!/bin/bash
# requires: change-review
# memory-audit scripts の検査。HOME を一時ディレクトリに差し替え、偽のメモリを作って実行する。実際の claude は起動しない。
set -u
# 2つ目の設定ディレクトリの名前。利用者の環境の名前を書かないよう、中立な名前を変数で持つ。
# 期待値の並び順が .claude/ の後になるよう、「/」より後に並ぶ文字（_）で区切る。
ALT_DIR=.claude_alt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/memory-audit-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export CLAUDE_REPORTS_ROOT="$WORK/reports"
export CLAUDE_REPORTS_STATE="$WORK/state"
unset MEMORY_AUDIT_TARGETS CLAUDE_REVIEW_PROPOSALS CLAUDE_REVIEW_STATE XDG_CONFIG_HOME CLAUDE_REVIEW_DENY_READ
# 起動するコマンドは常に偽物にする（本物の claude を起動しない）。共通の設定ファイルは一時の場所を指す。
export CLAUDE_LAUNCHER="$WORK/fake-claude"
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
export CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude:$HOME/${ALT_DIR}"
# 記録を作るスクリプトは、リポジトリの core のものを使う。
CR_REAL="$(cd "$SCRIPT_DIR/../../change-review/scripts" && pwd -P)"
export CHANGE_REVIEW_SCRIPTS="$CR_REAL"
export CLAUDE_REVIEW_CHANGES_LOG="$WORK/changes/log.md"
export CLAUDE_CHANGE_LEDGER="$WORK/change-ledger"
unset CLAUDE_REVIEW_GUARDED_PATHS SKILL_AUDIT_PROTECTED
PDIR="$CLAUDE_REPORTS_ROOT/proposals"
LEDGER="$HOME/.local/state/claude-review-inbox"
STATE="$CLAUDE_REPORTS_STATE/memory-audit"
RDIR="$CLAUDE_REPORTS_ROOT/memory-audit"

NL=$'\n'
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽の HOME。設定ディレクトリを2つ持つ形にする。
mkdir -p "$HOME/.claude/projects/proj-a/memory" "$HOME/.claude/projects/proj-b" \
  "$HOME/${ALT_DIR}/projects/proj-c/memory/sub"
echo "a1" >"$HOME/.claude/projects/proj-a/memory/a.md"
echo "c1" >"$HOME/${ALT_DIR}/projects/proj-c/memory/sub/c.md"
M_A="$HOME/.claude/projects/proj-a/memory"
M_C="$HOME/${ALT_DIR}/projects/proj-c/memory"
# 作業用のフォルダの中での位置。.claude で始まる要素は先頭のドットを外して写される。
S_A="$HOME/claude/projects/proj-a/memory"
S_C="$HOME/${ALT_DIR#.}/projects/proj-c/memory"

# レポートを書く偽の claude。受け取った引数を記録し、依頼文から書き込み先（.staging）を読んで STAGE に入れ、
# FAKE_HOOK のコマンドを実行する（直した版を書く処理を検査ごとに差し替える）。
FAKE="$WORK/fake-claude"
cat >"$FAKE" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_ARGS"
while [ $# -gt 0 ]; do
  if [ "$1" = "-p" ]; then
    out="${2##*レポートの出力先は }"
    out="${out%%。*}"
    printf '# メモリ精査レポート\n\n検査用\n' >"$out"
    STAGE="${2##*直した版の書き込み先は }"
    STAGE="${STAGE%%（*}"
    export STAGE
  fi
  shift
done
if [ -n "${FAKE_HOOK:-}" ]; then
  bash -c "$FAKE_HOOK" || exit 9
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FAKE"
export FAKE_ARGS="$WORK/fake-args"

echo "== 既定の targets.conf"
check "既定の中身は設定ディレクトリごとのメモリの1行" '[ "$(cat "$SCRIPT_DIR/targets.conf")" = "\$CONFIG_DIR/projects/*/memory" ]'

echo "== --dry-run の範囲と書き換えの拒否"
out="$("$SCRIPT_DIR/run.sh" --dry-run)"; rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "対象は memory を持つ2件だけ" '[ "$(printf "%s\n" "$out" | grep -c "^TARGET: ")" = 2 ]'
has() { printf '%s' "$out" | grep -Fq -- "$1"; }
for rule in "'--model' 'opus' '--effort' 'low'" "'--permission-mode' 'default'" \
  "Read(/$HOME/.claude/**)" "Read(/$HOME/${ALT_DIR}/**)" "Read(/$PDIR/**)" \
  "Read(/$HOME/Library/CloudStorage/**)" "Read(/$HOME/.config/claude-skills/memory-audit.local.md)" \
  "Edit(/$M_A/**)" "Edit(/$M_C/**)" "Edit(/$CLAUDE_REVIEW_CHANGES_LOG)" \
  "Edit(/$PDIR/**)" "Edit(/$LEDGER/**)" "Edit(/$HOME/.claude/skills/**)" \
  "Edit(/$HOME/.claude/settings.json)" "Edit(/$HOME/.claude/CLAUDE.md)" \
  "| No | 消える記述 | 行き先 | 場所 |" "cd '$RDIR' &&"; do
  check "dry-run の出力に含む: $rule" 'has "$rule"'
done
allow_part="$(printf '%s' "$out" | sed -n "s/.*'--allowedTools'\(.*\)'--disallowedTools'.*/\1/p")"
check "許可の Edit は作業用と結果だけ" '[ "$(printf "%s" "$allow_part" | grep -o "Edit(" | wc -l | tr -d " ")" = 2 ]'
check "元のメモリと記録の Edit を許可しない" '! printf "%s" "$allow_part" | grep -Fq "Edit(/$M_A/" && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$CLAUDE_REVIEW_CHANGES_LOG)"'
check "任意の読み取りと削除の Bash を許可しない" '! has "Bash(rm" && ! has "Bash(mv" && ! has "Bash(curl" && ! printf "%s" "$allow_part" | grep -Fq "'"'"'Read'"'"'"'
check "dry-run は複製と記録を作らない" '[ -z "$(ls "$RDIR/.snapshots")" ] && [ ! -e "$CLAUDE_REVIEW_CHANGES_LOG" ]'
check "lock を解放する" '[ ! -d "$STATE/lock" ]'

# 項目の取り出しは ID ごとに行い、他の項目の区分と取り違えない。
entry_for() {
  awk -v t="$1" '/^## / { if (found) { printf "%s", entry; exit } entry=$0 "\n"; found=0; next }
    { entry=entry $0 "\n"; if ($0 ~ /^- 対象: / && index($0, "`" t "`")) found=1 }
    END { if (found) printf "%s", entry }' "$CLAUDE_REVIEW_CHANGES_LOG"
}

echo "== 追加・修正・削除は記録するだけ"
export M_A M_C S_A S_C WORK
printf 'edit old\n' >"$M_A/edit.md"
printf 'remove old\n' >"$M_A/remove.md"
printf 'keep old\n' >"$M_A/keep.md"
printf -- '- [Remove](remove.md)\n- [A](a.md)\n' >"$M_A/MEMORY.md"
cp -Rp "$M_A" "$WORK/before"
HOOK='mkdir -p "$STAGE$S_A" "$STAGE/destinations$S_A/edit.md" "$STAGE/destinations$S_A/remove.md" &&
printf "a1\na2\n" >"$STAGE$S_A/a.md" &&
printf "new file\n" >"$STAGE$S_A/new.md" &&
printf "edit new\n" >"$STAGE$S_A/edit.md" &&
printf -- "- [A](a.md)\n" >"$STAGE$S_A/MEMORY.md" &&
printf "%s\t%s\n" "$M_A/remove.md" "重複した経緯" >"$STAGE/deletions.tsv" &&
for name in edit.md remove.md; do
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | 古い経緯 | 決まりではない（経緯の記録） | — |\n" >"$STAGE/destinations$S_A/$name/table.md"
done'
FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run.sh"; rc=$?
check "正常終了" '[ "$rc" -eq 0 ]'
check "元のメモリと索引を一切書き換えない" 'diff -r "$WORK/before" "$M_A" >/dev/null'
check "新しいファイルを元の場所に作らない" '[ ! -e "$M_A/new.md" ]'
check "追加2件・修正1件・削除1件を記録する" '[ "$(grep -c "^## " "$CLAUDE_REVIEW_CHANGES_LOG")" = 4 ]'
check "全項目は未対応" '[ "$(grep -c "^- 状態: 未対応$" "$CLAUDE_REVIEW_CHANGES_LOG")" = 4 ]'
check "ID はジョブ名・日時・連番" '[ "$(grep -Ec "^## .* memory-audit-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-[0-9]{2}$" "$CLAUDE_REVIEW_CHANGES_LOG")" = 4 ]'
check "表がそろった変更は直してよい" '[ "$(grep -c "^- 区分: 直してよい$" "$CLAUDE_REVIEW_CHANGES_LOG")" = 4 ]'
edit="$(entry_for "$M_A/edit.md")"; deletion="$(entry_for "$M_A/remove.md")"
check "差分の見出しは元の絶対パス" 'printf "%s" "$edit" | grep -Fxq -- "--- $M_A/edit.md" && printf "%s" "$edit" | grep -Fxq "+++ $M_A/edit.md"'
check "修正の差分を全体記録する" 'printf "%s" "$edit" | grep -Fxq -- "-edit old" && printf "%s" "$edit" | grep -Fxq "+edit new"'
check "削除と索引の行の削除は同じ項目" 'printf "%s" "$deletion" | grep -Fxq -- "--- $M_A/MEMORY.md" && printf "%s" "$deletion" | grep -Fxq -- "-- [Remove](remove.md)"'
check "索引だけの項目を作らない" '! grep -q "^- 直したいこと: メモリ proj-a/MEMORY.md" "$CLAUDE_REVIEW_CHANGES_LOG"'
check "台帳と案のファイルは新しく作らない" '[ ! -e "$CLAUDE_CHANGE_LEDGER" ] && [ ! -e "$PDIR" ]'
rep="$(ls -t "$RDIR/"*.md | head -1)"
check "結果は ID・区分・対象・要約を載せる" 'grep -Fxq "## 記録に足した直したいこと（ID・区分・対象・要約）" "$rep" && grep -Eq "^- memory-audit-.*・直してよい・" "$rep"'
check "結果は Claude の本文を残す" 'grep -Fq "検査用" "$rep"'
check "複製と作業用の版を残す" '[ -n "$(find "$RDIR/.snapshots" -name a.md)" ] && [ -n "$(find "$RDIR/.staging" -name new.md)" ]'

# 区分の確認に使う項目は前の実行とは別名にする。
echo "== 要確認の判定"
printf 'old\n' >"$M_A/needs.md"
printf 'old\n' >"$M_A/missing.md"
printf 'old\n' >"$M_A/twice.md"
printf 'permissions.deny を守る\n' >"$M_A/safety.md"
for id in old-1 old-2; do
  bash "$CR_REAL/corrections.sh" add --id "$id" --kind memory-audit/修正/proj-a/twice.md --target "$M_A/twice.md" --correct '正しくは元の記述を残す' >/dev/null
done
HOOK='mkdir -p "$STAGE$S_A" &&
for name in needs.md missing.md twice.md safety.md; do
printf "new\n" >"$STAGE$S_A/$name"
mkdir -p "$STAGE/destinations$S_A/$name"
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | 古い経緯 | 決まりではない（経緯の記録） | — |\n" >"$STAGE/destinations$S_A/$name/table.md"
done &&
rm "$STAGE/destinations$S_A/missing.md/table.md" &&
printf "%s\t%s\n" "$M_A/needs.md" "判断に迷う" >"$STAGE/needs-approval.tsv"'
FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run.sh"; rc=$?
check "判定があっても正常終了" '[ "$rc" -eq 0 ]'
for name in needs.md missing.md twice.md safety.md; do
  item="$(entry_for "$M_A/$name")"
  check "${name} は要確認" 'printf "%s" "$item" | grep -q "^- 区分: 要確認（"'
  check "${name} は元のファイルを直さない" '[ "$(cat "$M_A/$name")" != new ]'
done
check "needs-approval の判断理由を残す" 'entry_for "$M_A/needs.md" | grep -Fq "判断に迷う"'
check "訂正2回の理由を残す" 'entry_for "$M_A/twice.md" | grep -Fq "2 回訂正"'

echo "== 複製後の並行更新を差分の基準にしない"
printf 'snapshot old\n' >"$M_A/concurrent.md"
printf 'snapshot unchanged\n' >"$M_A/unchanged.md"
HOOK='mkdir -p "$STAGE$S_A" &&
printf "concurrent current\n" >"$M_A/concurrent.md" &&
printf "candidate new\n" >"$STAGE$S_A/concurrent.md" &&
printf "unchanged current\n" >"$M_A/unchanged.md" &&
printf "snapshot unchanged\n" >"$STAGE$S_A/unchanged.md" &&
printf "created concurrently\n" >"$M_A/created.md" &&
printf "candidate created\n" >"$STAGE$S_A/created.md"'
FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run.sh"; rc=$?
check "並行更新後も記録は正常終了" '[ "$rc" -eq 0 ]'
check "並行更新された現物を候補で書き換えない" '[ "$(cat "$M_A/concurrent.md")" = "concurrent current" ] && [ "$(cat "$M_A/unchanged.md")" = "unchanged current" ] && [ "$(cat "$M_A/created.md")" = "created concurrently" ]'
item="$(entry_for "$M_A/concurrent.md")"
check "修正の削除行は複製の old である" 'printf "%s" "$item" | grep -Fxq -- "-snapshot old" && printf "%s" "$item" | grep -Fxq "+candidate new" && ! printf "%s" "$item" | grep -Fxq -- "-concurrent current"'
check "複製と同じ候補は現物が更新されても記録しない" '! grep -Fq -- "--- $M_A/unchanged.md" "$CLAUDE_REVIEW_CHANGES_LOG"'
item="$(entry_for "$M_A/created.md")"
check "複製後に同名の現物が作られても追加として記録する" 'printf "%s" "$item" | grep -Fq "の追加（memory-audit" && printf "%s" "$item" | grep -Fxq "+candidate created" && ! printf "%s" "$item" | grep -Fxq -- "-created concurrently"'

echo "== 範囲外・リンク・不正パスは記録しない"
before_n="$(grep -c '^## ' "$CLAUDE_REVIEW_CHANGES_LOG")"
HOOK='mkdir -p "$STAGE$S_A/sub" "$STAGE/other" && printf x >"$STAGE$S_A/x..y.md" && printf x >"$STAGE$S_A/a.txt" && printf x >"$STAGE$S_A/sub/a.md" && ln -s "$M_A/a.md" "$STAGE$S_A/link.md" && printf x >"$STAGE/other/a.md" && printf "%s\t%s\n" "$WORK/outside.md" "対象外" >"$STAGE/deletions.tsv"'
FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run.sh"; rc=$?
check "対象外の候補だけなら記録を増やさない" '[ "$rc" -eq 0 ] && [ "$(grep -c "^## " "$CLAUDE_REVIEW_CHANGES_LOG")" = "$before_n" ]'
rep="$(ls -t "$RDIR/"*.md | head -1)"
check "対象外の理由を結果へ載せる" 'grep -Fq "パスに .. を含む" "$rep" && grep -Fq "シンボリックリンクである" "$rep" && grep -Fq "直下ではない" "$rep"'

echo "== 異常終了では記録しない"
FAKE_RC=3 FAKE_HOOK='mkdir -p "$STAGE$S_A" && printf a3 >"$STAGE$S_A/a.md"' "$SCRIPT_DIR/run.sh"; rc=$?
check "終了コードを引き継ぐ" '[ "$rc" -eq 3 ]'
check "失敗した版を記録しない" '[ "$(grep -c "^## " "$CLAUDE_REVIEW_CHANGES_LOG")" = "$before_n" ]'
check "元のメモリを直さない" '[ "$(cat "$M_A/a.md")" = a1 ]'

# 拒否の規則が無ければ、偽物の Claude すら起動しない。
echo "== 必要なスクリプトが無ければ起動しない"
mkdir -p "$WORK/bare/memory-audit"
cp -Rp "$SCRIPT_DIR" "$WORK/bare/memory-audit/scripts"
rm -f "$FAKE_ARGS"
CHANGE_REVIEW_SCRIPTS="$WORK/nosuch" "$WORK/bare/memory-audit/scripts/run.sh"; rc=$?
check "規則が無ければ終了コード1" '[ "$rc" -eq 1 ]'
check "Claude を起動しない" '[ ! -f "$FAKE_ARGS" ]'
echo "== 設定ファイルで対象を変えられる"
conf="$WORK/targets-one.conf"
printf '# 1か所に絞る\n\n~/%s/projects/*/memory\n$HOME/nosuch/*/memory\n' "$ALT_DIR" >"$conf"
out="$(MEMORY_AUDIT_TARGETS="$conf" "$SCRIPT_DIR/run.sh" --dry-run)"
check "対象は1件" '[ "$(printf "%s\n" "$out" | grep -c "^TARGET: ")" = "1" ] && printf "%s" "$out" | grep -Fxq "TARGET: $M_C"'
check "許可は対象の1件だけ" '! printf "%s" "$out" | grep -Fq "Edit(/$M_A/**)"'
printf '$HOME/nosuch/*/memory\n' >"$conf"
MEMORY_AUDIT_TARGETS="$conf" "$SCRIPT_DIR/run.sh" --dry-run >/dev/null 2>&1
rc=$?
check "対象が0件なら終了コード1" '[ "$rc" -eq 1 ]'

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

echo "== 起動するコマンドの指定"
out="$(CLAUDE_LAUNCHER="/opt/launcher {job} --flag" "$SCRIPT_DIR/run.sh" --dry-run)"
check "{job} をジョブ名に置き換え、語ごとに渡す" 'printf "%s" "$out" | grep -Fq "&& '"'"'/opt/launcher'"'"' '"'"'memory-audit'"'"' '"'"'--flag'"'"' '"'"'-p'"'"'"'
printf 'CLAUDE_LAUNCHER=~/bin/launcher {job}\nCLAUDE_REVIEW_CONFIG_DIRS=~/.claude\nCLAUDE_REVIEW_DENY_READ=~/sync-a:/opt/sync-b\n' >"$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u CLAUDE_LAUNCHER -u CLAUDE_REVIEW_CONFIG_DIRS "$SCRIPT_DIR/run.sh" --dry-run)"
check "設定ファイルの起動コマンドを使い、~ を展開する" 'printf "%s" "$out" | grep -Fq "&& '"'"'$HOME/bin/launcher'"'"' '"'"'memory-audit'"'"' '"'"'-p'"'"'"'
check "設定ファイルの設定ディレクトリだけを対象にする" '[ "$(printf "%s\n" "$out" | grep -c "^TARGET: ")" = "1" ] && ! printf "%s" "$out" | grep -Fq "${ALT_DIR}"'
check "設定ファイルの読み取りの拒否を足す" 'printf "%s" "$out" | grep -Fq "'"'"'Read(/$HOME/sync-a/**)'"'"' '"'"'Read(//opt/sync-b/**)'"'"'"'
out="$(CLAUDE_LAUNCHER=/opt/env-launcher "$SCRIPT_DIR/run.sh" --dry-run)"
check "環境変数が設定ファイルより優先する" 'printf "%s" "$out" | grep -Fq "&& '"'"'/opt/env-launcher'"'"' '"'"'-p'"'"'"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
mkdir -p "$HOME/.local/bin"
ln -sfn "$FAKE" "$HOME/.local/bin/claude"
sleep 1
rm -f "$FAKE_ARGS"
env -u CLAUDE_LAUNCHER "$SCRIPT_DIR/run.sh"
log1="$(ls -1t "$STATE/logs/"*.log | head -1)"
check "指定が無ければ claude を起動する" 'grep -Fxq -- "-p" "$FAKE_ARGS" && grep -Fxq -- "--disallowedTools" "$FAKE_ARGS"'
check "起動に使うコマンドをログに書く" 'grep -q "起動に使うコマンド: claude$" "$log1"'
check "claude をコマンドとして組み立てる" 'grep -Fq "&& '"'"'claude'"'"' '"'"'-p'"'"'" "$log1"'

echo "== plist のひな形"
PL="$WORK/memory-audit.plist"
sed -e "s|@@LABEL@@|com.example.memory-audit|g" -e "s|@@SCRIPT@@|/path/to/run.sh|g" -e "s|@@HOME@@|$WORK/home|g" \
  "$SCRIPT_DIR/../launchd/memory-audit.plist.template" >"$PL"
plutil -lint "$PL"
rc=$?
check "plutil -lint が通る" '[ "$rc" -eq 0 ]'
check "毎週月曜 10:30" '[ "$(plutil -extract StartCalendarInterval.Weekday raw "$PL")" = "1" ] && [ "$(plutil -extract StartCalendarInterval.Hour raw "$PL")" = "10" ] && [ "$(plutil -extract StartCalendarInterval.Minute raw "$PL")" = "30" ]'

echo "== 実行権限"
for f in run.sh test.sh; do
  check "実行権限: $f" '[ -x "$SCRIPT_DIR/$f" ]'
done

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
