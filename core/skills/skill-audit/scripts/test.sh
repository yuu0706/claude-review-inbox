#!/bin/bash
# skill-audit scripts の検査。一時ディレクトリに偽の ROOT を作って実行する。実際の claude は起動しない。
set -u
# 2つ目の設定ディレクトリの名前。利用者の環境の名前を書かないよう、中立な名前を変数で持つ。
ALT_DIR=.claude_alt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/skill-audit-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
# 本物の HOME の下のスキル・案の置き場所・状態を探さないよう、HOME を一時ディレクトリにする。
export HOME="$WORK/home"
mkdir -p "$HOME/.claude" "$HOME/${ALT_DIR}"

export SKILL_AUDIT_ROOT="$WORK/root"
export SKILL_AUDIT_STATE="$WORK/state"
export SKILL_AUDIT_EXCLUDE="synced plugins vendored"
unset XDG_CONFIG_HOME CLAUDE_REVIEW_DENY_READ SKILL_AUDIT_OWN_LINK_ROOTS
# 起動するコマンドは常に偽物にする（本物の claude を起動しない）。共通の設定ファイルは一時の場所を指す。
export CLAUDE_LAUNCHER=true
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
export CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude:$HOME/${ALT_DIR}"
# 否認・訂正のリストと台帳は一時ディレクトリにする。記録のスクリプトは core のものを使う。
export CLAUDE_REVIEW_PROPOSALS="$WORK/proposals"
export CLAUDE_REVIEW_STATE="$WORK/review-state"
export CHANGE_REVIEW_SCRIPTS="$(cd "$SCRIPT_DIR/../../change-review/scripts" && pwd -P)"
export CLAUDE_REVIEW_CHANGES_LOG="$WORK/changes/log.md"
export CLAUDE_CHANGE_LEDGER="$WORK/change-ledger"
unset CLAUDE_REVIEW_GUARDED_PATHS SKILL_AUDIT_PROTECTED
PDIR="$CLAUDE_REVIEW_PROPOSALS"
R="$SKILL_AUDIT_ROOT"
# 変更の記録と直す前の複製は、スキル置き場の外の状態の置き場所に置く。
HF="$SKILL_AUDIT_STATE/history.md"
HD="$SKILL_AUDIT_STATE/history"
NL=$'\n'

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽の ROOT を作る
mkdir -p "$R/alpha/sub" "$R/beta" "$R/synced/x" "$R/plugins/x" "$R/vendored" \
  "$R/.trash/old" "$R/skill-audit" "$HD/2000-01-01" "$WORK/external/linked"
echo "alpha" >"$R/alpha/SKILL.md"
echo "alpha sub" >"$R/alpha/sub/ref.md"
echo "beta" >"$R/beta/SKILL.md"
echo "vendored" >"$R/vendored/SKILL.md"
echo "audit" >"$R/skill-audit/SKILL.md"
echo "old" >"$HD/2000-01-01/x.bak"
echo "linked" >"$WORK/external/linked/SKILL.md"
ln -s "$WORK/external/linked" "$R/linked"
ln -s "$WORK/external" "$R/alpha/link-dir"

echo "== list_targets"
targets="$(. "$SCRIPT_DIR/lib.sh"; list_targets | tr '\n' ' ')"
check "list_targets は alpha beta skill-audit のみ（実際: ${targets}）" '[ "$targets" = "alpha beta skill-audit " ]'

echo "== snapshot.sh"
day="$(date '+%Y-%m-%d')"
hist="$HD/$day"
"$SCRIPT_DIR/snapshot.sh" alpha sub/ref.md >/dev/null
check "正常系で退避される" '[ -f "$hist/alpha__sub_ref.md.bak" ] && cmp -s "$hist/alpha__sub_ref.md.bak" "$R/alpha/sub/ref.md"'
echo "changed" >"$R/alpha/sub/ref.md"
"$SCRIPT_DIR/snapshot.sh" alpha sub/ref.md >/dev/null
check "同日2回目は上書きしない" '[ "$(cat "$hist/alpha__sub_ref.md.bak")" = "alpha sub" ]'
for args in "synced x" "vendored SKILL.md" "linked SKILL.md" ".trash old" "nosuch SKILL.md" \
  "alpha ../beta/SKILL.md" "alpha sub/../SKILL.md" "alpha /etc/hosts" "alpha link-dir/linked/SKILL.md" \
  "alpha nosuch.md" "alpha sub"; do
  # shellcheck disable=SC2086
  "$SCRIPT_DIR/snapshot.sh" $args 2>/dev/null
  rc=$?
  check "拒否する: snapshot.sh ${args}（rc=${rc}）" '[ "$rc" -eq 1 ]'
done

echo "== trash-skill.sh"
check "rm を使っていない" '! grep -Eq "(^|[^a-z_-])rm( |$)" "$SCRIPT_DIR/trash-skill.sh"'
"$SCRIPT_DIR/trash-skill.sh" beta >/dev/null
moved="$(ls -d "$R/.skill-audit-trash/"*-beta 2>/dev/null)"
check "正常系で .skill-audit-trash へ移動される" '[ ! -e "$R/beta" ] && [ -f "$moved/SKILL.md" ]'
for name in synced plugins vendored linked .trash skill-audit nosuch "../root/alpha" "alpha/sub" ".." ""; do
  "$SCRIPT_DIR/trash-skill.sh" "$name" 2>/dev/null
  rc=$?
  check "拒否する: trash-skill.sh '$name'（rc=${rc}）" '[ "$rc" -eq 1 ]'
done
check "拒否後も対象が残っている" '[ -d "$R/synced" ] && [ -L "$R/linked" ] && [ -d "$R/skill-audit" ] && [ -d "$WORK/external/linked" ]'
mv "$moved" "$R/beta"

echo "== run-audit.sh --dry-run"
out="$("$SCRIPT_DIR/run-audit.sh" --dry-run)"; rc=$?
check "初回は正常終了" '[ "$rc" -eq 0 ]'
allow_part="$(printf '%s' "$out" | sed -n "s/.*'--allowedTools'\(.*\)'--disallowedTools'.*/\1/p")"
deny_part="${out#*--disallowedTools}"
for rule in "Edit(/$R/**)" "Edit(/$CLAUDE_REVIEW_CHANGES_LOG)" "Edit(/$HF)" "Edit(/$HD/**)" \
  "Edit(/$PDIR/**)" "Edit(/$CLAUDE_REVIEW_STATE/**)" "Edit(/$HOME/.claude/CLAUDE.md)" \
  "Edit(/$HOME/.claude/settings.json)" "Read(/$HOME/Library/CloudStorage/**)"; do
  check "拒否側に含む: $rule" 'printf "%s" "$deny_part" | grep -Fq "$rule"'
done
check "元のスキルの Edit を許可しない" '! printf "%s" "$allow_part" | grep -Fq "Edit(/$R/"'
check "履歴と記録の Edit を許可しない" '! printf "%s" "$allow_part" | grep -Fq "Edit(/$HF)" && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$CLAUDE_REVIEW_CHANGES_LOG)"'
check "snapshot と trash の Bash を許可しない" '! printf "%s" "$allow_part" | grep -Eq "Bash\\(.*(snapshot|trash-skill)"'
check "作業用の複製を編集する" 'printf "%s" "$allow_part" | grep -Eq "Edit\\(/.*/staging/\\*\\*\\)"'
check "dry-run は実行の複製と last-hash を作らない" '[ ! -e "$SKILL_AUDIT_STATE/runs" ] && [ ! -e "$SKILL_AUDIT_STATE/last-hash" ]'
check "dry-run はログを作らない" '[ -z "$(ls "$SKILL_AUDIT_STATE/logs")" ]'
check "lock を解放する" '[ ! -d "$SKILL_AUDIT_STATE/lock" ]'
echo "== run-audit.sh 通常実行（CLAUDE_LAUNCHER=true）"
"$SCRIPT_DIR/run-audit.sh"
rc=$?
log1="$(ls -1t "$SKILL_AUDIT_STATE/logs/"*.log | head -1)"
check "通常実行は終了コード0" '[ "$rc" -eq 0 ]'
check "ログが作られる" '[ -f "$log1" ] && grep -q "last-hash を更新しました" "$log1"'
check "last-hash が作られる" '[ -s "$SKILL_AUDIT_STATE/last-hash" ]'
check "lock が解放されている" '[ ! -d "$SKILL_AUDIT_STATE/lock" ]'

echo "== 変更なしのスキップ"
out="$("$SCRIPT_DIR/run-audit.sh" --dry-run)"
check "変更なしの dry-run はスキップされる" 'printf "%s" "$out" | grep -q "変更なし" && ! printf "%s" "$out" | grep -q -- "--allowedTools"'
sleep 1
"$SCRIPT_DIR/run-audit.sh"
log2="$(ls -1t "$SKILL_AUDIT_STATE/logs/"*.log | head -1)"
check "変更なしの通常実行はスキップをログに書く" '[ "$log2" != "$log1" ] && grep -q "変更なし" "$log2"'

echo "== --force"
out="$("$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "--force ではスキップされない" 'printf "%s" "$out" | grep -q -- "--allowedTools"'

echo "== 追加・修正・削除は記録するだけ"
FAKE="$WORK/fake-claude"
cat >"$FAKE" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_ARGS"
export STAGE="$PWD"
export RUN_DIR="${PWD%/staging}"
export DEST="$RUN_DIR/destinations"
if [ -n "${FAKE_HOOK:-}" ]; then bash -c "$FAKE_HOOK" || exit 9; fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FAKE"
export FAKE_ARGS="$WORK/fake-args" SCRIPT_DIR R HF HD WORK
entry_for() {
  awk -v t="$1" '/^## / { if (found) { printf "%s", entry; exit } entry=$0 "\n"; found=0; next }
    { entry=entry $0 "\n"; if ($0 ~ /^- 対象: / && index($0, "`" t "`")) found=1 }
    END { if (found) printf "%s", entry }' "$CLAUDE_REVIEW_CHANGES_LOG"
}
printf 'alpha\nold\n' >"$R/alpha/SKILL.md"
printf 'beta\n- gamma を使う\n' >"$R/beta/SKILL.md"
mkdir -p "$R/gamma" "$R/security-rules"
printf 'gamma\n' >"$R/gamma/SKILL.md"
printf 'secret rule\n' >"$R/security-rules/SKILL.md"
cp -Rp "$R" "$WORK/before-root"
printf '# 既存の変更履歴\n' >"$HF"
HOOK='printf "alpha\nnew\n" >"$STAGE/alpha/SKILL.md" &&
printf "new file\n" >"$STAGE/alpha/new.md" &&
printf "beta\n" >"$STAGE/beta/SKILL.md" &&
printf "%s\t%s\n" "$R/gamma" "重複" "$R/alpha/sub/ref.md" "古い経緯" >"$RUN_DIR/deletions.tsv" &&
printf "updated rule\n" >"$STAGE/security-rules/SKILL.md" &&
mkdir -p "$STAGE/new-skill" && printf "new skill\n" >"$STAGE/new-skill/SKILL.md" &&
for target in "$R/alpha/SKILL.md" "$R/alpha/sub/ref.md" "$R/gamma" "$R/security-rules/SKILL.md"; do
D="$DEST$target"; mkdir -p "$D"
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | 古い経緯 | 決まりではない（経緯の記録） | — |\n" >"$D/table.md"
done'
CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run-audit.sh" --force; rc=$?
check "正常終了" '[ "$rc" -eq 0 ]'
check "元のスキルは追加・修正・削除とも変更しない" 'diff -r "$WORK/before-root" "$R" >/dev/null'
check "history.md に反映の記録を足さない" '[ "$(cat "$HF")" = "# 既存の変更履歴" ]'
check "新しい台帳を作らない" '[ ! -e "$CLAUDE_CHANGE_LEDGER" ]'
check "追加2件・修正2件・削除2件を記録する" '[ "$(grep -c "^## " "$CLAUDE_REVIEW_CHANGES_LOG")" = 6 ]'
check "全項目が未対応" '[ "$(grep -c "^- 状態: 未対応$" "$CLAUDE_REVIEW_CHANGES_LOG")" = 6 ]'
check "安全の規則以外は直してよい" '[ "$(grep -c "^- 区分: 直してよい$" "$CLAUDE_REVIEW_CHANGES_LOG")" = 5 ]'
check "安全の規則の修正は要確認" 'entry_for "$R/security-rules/SKILL.md" | grep -Fq "区分: 要確認（安全のための規則のスキル"'
check "スキルの削除と参照の修正をまとめる" 'entry_for "$R/gamma" | grep -Fxq -- "--- $R/beta/SKILL.md" && entry_for "$R/gamma" | grep -Fxq -- "-- gamma を使う"'
check "参照の修正を別項目にしない" '! grep -q "^- 直したいこと: beta/" "$CLAUDE_REVIEW_CHANGES_LOG"'
check "差分の見出しは元の絶対パス" 'entry_for "$R/alpha/new.md" | grep -Fxq -- "--- $R/alpha/new.md" && entry_for "$R/alpha/new.md" | grep -Fxq "+++ $R/alpha/new.md"'
rep="$(ls -t "$HOME/claude-reports/skill-audit/"*.md | head -1)"
check "結果は ID・区分・対象・要約を載せる" 'grep -Fxq "## 記録に足した直したいこと（ID・区分・対象・要約）" "$rep" && grep -Eq "^- skill-audit-.*・直してよい・" "$rep"'

# 元の対象に対する南京錠を、自作のリンクの実体にも付ける。
echo "== 自作のスキルのリンクも元の実体を直さない"
mkdir -p "$WORK/own/own-link"
printf 'own old\n' >"$WORK/own/own-link/SKILL.md"
ln -s "$WORK/own/own-link" "$R/own-link"
out="$(SKILL_AUDIT_OWN_LINK_ROOTS="$WORK/own" "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
allow_part="$(printf '%s' "$out" | sed -n "s/.*'--allowedTools'\(.*\)'--disallowedTools'.*/\1/p")"
deny_part="${out#*--disallowedTools}"
check "リンクの実体は拒否側にだけ出す" 'printf "%s" "$deny_part" | grep -Fq "Edit(/$WORK/own/own-link/**)" && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$WORK/own/own-link/**)"'
SKILL_AUDIT_OWN_LINK_ROOTS="$WORK/own" CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK='printf "own old\nadded\n" >"$STAGE/own-link/SKILL.md"' "$SCRIPT_DIR/run-audit.sh" --force; rc=$?
check "元のリンクと実体を保つ" '[ "$rc" -eq 0 ] && [ -L "$R/own-link" ] && [ "$(cat "$WORK/own/own-link/SKILL.md")" = "own old" ]'
check "自作のリンクの追加も記録する" 'entry_for "$R/own-link/SKILL.md" | grep -Fxq "+added"'
rm "$R/own-link"

echo "== 新規のトップレベル項目も対象範囲を守る"
before_n="$(grep -c '^## ' "$CLAUDE_REVIEW_CHANGES_LOG")"
HOOK='mkdir -p "$STAGE/linked" "$STAGE/incomplete" &&
printf "outside candidate\n" >"$STAGE/linked/SKILL.md" &&
printf "single file\n" >"$STAGE/single.md" &&
printf "no skill file\n" >"$STAGE/incomplete/ref.md" &&
ln -s "$WORK/external/linked" "$STAGE/new-link"'
CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run-audit.sh" --force; rc=$?
check "対象外のリンクと同名のスキル候補を記録しない" '[ "$rc" -eq 0 ] && ! grep -Fq -- "--- $R/linked/SKILL.md" "$CLAUDE_REVIEW_CHANGES_LOG"'
check "単独ファイル・SKILL.mdなし・リンクの新規項目を記録しない" '[ "$(grep -c "^## " "$CLAUDE_REVIEW_CHANGES_LOG")" = "$before_n" ]'
check "元の対象外リンクの実体を変更しない" '[ -L "$R/linked" ] && [ "$(cat "$WORK/external/linked/SKILL.md")" = linked ]'
rep="$(ls -t "$HOME/claude-reports/skill-audit/"*.md | head -1)"
check "同名の対象外項目を拒否した理由を結果へ載せる" 'grep -Fq "対象外の項目と同名" "$rep"'
check "新規スキルの条件に合わない理由を結果へ載せる" 'grep -Fq "非リンクディレクトリと SKILL.md がそろっていない" "$rep"'

echo "== needs-approval・訂正2回・移し先の欠け"
printf 'twice old\n' >"$R/alpha/twice.md"
printf 'needs old\n' >"$R/alpha/needs.md"
printf 'missing old\n' >"$R/beta/missing.md"
for id in old-1 old-2; do
  bash "$CHANGE_REVIEW_SCRIPTS/corrections.sh" add --id "$id" --kind skill-audit/修正/alpha --target "$R/alpha/twice.md" --correct '正しくは元の記述を残す' >/dev/null
done
HOOK='printf "twice new\n" >"$STAGE/alpha/twice.md" && printf "needs new\n" >"$STAGE/alpha/needs.md" && printf "missing new\n" >"$STAGE/beta/missing.md" && printf "%s\t%s\n" "$R/alpha/needs.md" "判断に迷う" >"$RUN_DIR/needs-approval.tsv" &&
for name in twice.md needs.md; do
D="$DEST$R/alpha/$name"; mkdir -p "$D"
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | 古い経緯 | 決まりではない（経緯の記録） | — |\n" >"$D/table.md"
done'
CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run-audit.sh" --force; rc=$?
check "判定して正常終了" '[ "$rc" -eq 0 ]'
check "訂正2回は要確認" 'entry_for "$R/alpha/twice.md" | grep -Fq "区分: 要確認（同じ種類"'
check "needs-approval の理由は要確認" 'entry_for "$R/alpha/needs.md" | grep -Fq "判断に迷う"'
check "表の欠けは要確認" 'entry_for "$R/beta/missing.md" | grep -q "^- 区分: 要確認（"'
check "3件とも元のファイルを直さない" '[ "$(cat "$R/alpha/twice.md")" = "twice old" ] && [ "$(cat "$R/alpha/needs.md")" = "needs old" ] && [ "$(cat "$R/beta/missing.md")" = "missing old" ]'

echo "== リンクをたどる削除の候補は拒否する"
CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK='printf "%s\t%s\n" "$R/alpha/link-dir/linked" "対象外" >"$RUN_DIR/deletions.tsv"' "$SCRIPT_DIR/run-audit.sh" --force; rc=$?
check "削除の候補でリンク先を消さない" '[ "$rc" -eq 0 ] && [ -f "$WORK/external/linked/SKILL.md" ]'

echo "== 必要なスクリプトが無ければ起動しない"
mkdir -p "$WORK/bare/skill-audit"
cp -Rp "$SCRIPT_DIR" "$WORK/bare/skill-audit/scripts"
rm -f "$FAKE_ARGS"
CHANGE_REVIEW_SCRIPTS="$WORK/nosuch" CLAUDE_LAUNCHER="$FAKE" "$WORK/bare/skill-audit/scripts/run-audit.sh" --force; rc=$?
check "規則が無ければ終了コード1" '[ "$rc" -eq 1 ]'
check "Claude を起動しない" '[ ! -f "$FAKE_ARGS" ]'
mkdir -p "$WORK/bare/change-review/scripts"
cp "$CHANGE_REVIEW_SCRIPTS/link-scopes.sh" "$WORK/bare/change-review/scripts/"
CHANGE_REVIEW_SCRIPTS="$WORK/nosuch" CLAUDE_LAUNCHER="$FAKE" "$WORK/bare/skill-audit/scripts/run-audit.sh" --force; rc=$?
check "記録のスクリプトが無くても起動しない" '[ "$rc" -eq 1 ] && [ ! -f "$FAKE_ARGS" ]'

# hash の基準を、利用者が作ったファイルを含む今の状態へ進める。
"$SCRIPT_DIR/run-audit.sh" --force
echo "== 変更検出の範囲"
echo "new" >"$HD/2000-01-01/y.bak"
echo "x" >"$R/synced/x/new.md"
echo "x" >"$R/vendored/new.md"
echo "x" >"$WORK/external/linked/new.md"
out="$("$SCRIPT_DIR/run-audit.sh" --dry-run)"
check "history・除外・リンク先の変更は検出しない" 'printf "%s" "$out" | grep -q "変更なし"'
echo "x" >"$R/alpha/new.md"
out="$("$SCRIPT_DIR/run-audit.sh" --dry-run)"
check "対象内の変更は検出する" 'printf "%s" "$out" | grep -q -- "--allowedTools"'

echo "== 異常終了時は last-hash を更新しない"
before="$(cat "$SKILL_AUDIT_STATE/last-hash")"
CLAUDE_LAUNCHER=false "$SCRIPT_DIR/run-audit.sh"
rc=$?
check "異常終了は非0で last-hash 据え置き（rc=${rc}）" '[ "$rc" -ne 0 ] && [ "$(cat "$SKILL_AUDIT_STATE/last-hash")" = "$before" ]'

echo "== 二重起動の拒否"
mkdir "$SKILL_AUDIT_STATE/lock"
"$SCRIPT_DIR/run-audit.sh" --dry-run --force >/dev/null 2>&1
rc=$?
check "lock があれば終了コード1" '[ "$rc" -eq 1 ]'
check "他者の lock を消さない" '[ -d "$SKILL_AUDIT_STATE/lock" ]'
rmdir "$SKILL_AUDIT_STATE/lock"

echo "== ログの保持件数"
for i in $(seq 1 40); do touch -t "200001010000.$(printf '%02d' $((i % 60)))" "$SKILL_AUDIT_STATE/logs/old-$i.log"; done
"$SCRIPT_DIR/run-audit.sh"
n="$(ls "$SKILL_AUDIT_STATE/logs/"*.log | wc -l | tr -d ' ')"
check "ログは30件以下（実際: ${n}）" '[ "$n" -le 30 ]'

echo "== 起動するコマンドの指定"
out="$(CLAUDE_LAUNCHER="/opt/launcher {job} --flag" "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "{job} をジョブ名に置き換え、語ごとに渡す" 'printf "%s" "$out" | grep -Fq "&& '"'"'/opt/launcher'"'"' '"'"'skill-audit'"'"' '"'"'--flag'"'"' '"'"'-p'"'"'"'
printf 'CLAUDE_LAUNCHER=~/bin/launcher {job}\nCLAUDE_REVIEW_CONFIG_DIRS=~/.claude\n' >"$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u CLAUDE_LAUNCHER -u CLAUDE_REVIEW_CONFIG_DIRS "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "設定ファイルの起動コマンドを使い、~ を展開する" 'printf "%s" "$out" | grep -Fq "&& '"'"'$HOME/bin/launcher'"'"' '"'"'skill-audit'"'"' '"'"'-p'"'"'"'
check "設定ファイルの設定ディレクトリだけを使う" '! printf "%s" "$out" | grep -Fq "${ALT_DIR}"'
out="$(CLAUDE_LAUNCHER=/opt/env-launcher "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "環境変数が設定ファイルより優先する" 'printf "%s" "$out" | grep -Fq "&& '"'"'/opt/env-launcher'"'"' '"'"'-p'"'"'"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u SKILL_AUDIT_EXCLUDE "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "除外の指定が無ければ名前で除外しない" '! printf "%s" "$out" | grep -Fq "Edit(/$R/plugins/**)"'
printf 'SKILL_AUDIT_ROOT=%s\nSKILL_AUDIT_EXCLUDE=plugins\n' "$R" >"$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u SKILL_AUDIT_ROOT -u SKILL_AUDIT_EXCLUDE "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "設定ファイルの ROOT と除外の名前を使う" 'printf "%s" "$out" | grep -Fq "Edit(/$R/plugins/**)" && ! printf "%s" "$out" | grep -Fq "Edit(/$R/vendored/**)"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
mkdir -p "$WORK/alias-home/.claude"
ln -s "$R" "$WORK/alias-home/.claude/skills"
out="$(CLAUDE_REVIEW_CONFIG_DIRS="$WORK/alias-home/.claude" "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "設定ディレクトリの skills が ROOT へのリンクなら、その表記でも拒否する" 'printf "%s" "$out" | grep -Fq "Edit(/$WORK/alias-home/.claude/skills/synced/**)"'

echo "== 指定が無い場合"
mkdir -p "$HOME/.local/bin"
ln -sfn "$FAKE" "$HOME/.local/bin/claude"
sleep 1
rm -f "$FAKE_ARGS"
env -u CLAUDE_LAUNCHER "$SCRIPT_DIR/run-audit.sh" --force
log1="$(ls -1t "$SKILL_AUDIT_STATE/logs/"*.log | head -1)"
check "claude を起動する" 'grep -Fxq -- "-p" "$FAKE_ARGS" && grep -Fxq -- "--disallowedTools" "$FAKE_ARGS"'
check "起動に使うコマンドをログに書く" 'grep -q "起動に使うコマンド: claude$" "$log1"'
check "claude をコマンドとして組み立てる" 'grep -Fq "&& '"'"'claude'"'"' '"'"'-p'"'"'" "$log1"'

echo "== plist のひな形"
PL="$WORK/skill-audit.plist"
sed -e "s|@@LABEL@@|com.example.skill-audit|g" -e "s|@@SCRIPT@@|/path/to/run-audit.sh|g" -e "s|@@HOME@@|$WORK/home|g" \
  "$SCRIPT_DIR/../launchd/skill-audit.plist.template" >"$PL"
plutil -lint "$PL"
rc=$?
check "plutil -lint が通る" '[ "$rc" -eq 0 ]'

echo "== 実行権限"
for f in lib.sh snapshot.sh trash-skill.sh run-audit.sh test.sh; do
  check "実行権限: $f" '[ -x "$SCRIPT_DIR/$f" ]'
done

echo "== check-public.sh（公開版の点検。検査器はスタブ）"
CP="$SCRIPT_DIR/check-public.sh"
STUB="$WORK/public-check"
PUB_A="$WORK/public-a"
PUB_B="$WORK/public-b"
mkdir -p "$STUB" "$PUB_A" "$PUB_B"
# スタブの check.sh。対象のディレクトリにある rc ファイルの値を終了コードにし、引数を記録する。
cat >"$STUB/check.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${0%/*}/args.log"
rc="$(cat "$1/rc" 2>/dev/null || echo 0)"
[ "$rc" = "1" ] && printf 'core/a.md:3:sample-term\n'
[ "$rc" = "2" ] && printf 'ERROR: 一覧が空です\n' >&2
exit "$rc"
EOF
chmod +x "$STUB/check.sh"
export PUBLIC_CHECK_DIR="$STUB"
export CLAUDE_REPORTS_ROOT="$WORK/reports"
export SKILL_AUDIT_PUBLIC_DIRS="$WORK/public-dirs.txt"
RD="$CLAUDE_REPORTS_ROOT/skill-audit"

bash "$CP" >/dev/null 2>&1
rc=$?
check "一覧が無ければ何もしない（終了コード0・結果なし）" '[ "$rc" -eq 0 ] && [ ! -e "$RD" ] && [ ! -e "$STUB/args.log" ]'

printf '# 公開版\n\n%s\n%s/\n' "$PUB_A" "$PUB_B" >"$SKILL_AUDIT_PUBLIC_DIRS"
out="$(bash "$CP" 2>&1)"
rc=$?
check "当たりが無ければ終了コード0で結果を書かない" '[ "$rc" -eq 0 ] && [ ! -e "$RD" ] && printf "%s" "$out" | grep -q "当たりはありませんでした（2件）"'
check "各ディレクトリを収集込み（--no-collect なし）で調べる" '[ "$(cat "$STUB/args.log")" = "$PUB_A${NL}$PUB_B" ]'

echo 1 >"$PUB_B/rc"
out="$(bash "$CP" 2>&1)"
rc=$?
rep="$(ls -1 "$RD/"*.md 2>/dev/null | head -1)"
check "当たりがあれば終了コード1で結果を書く" '[ "$rc" -eq 1 ] && [ -f "$rep" ]'
check "結果のファイル名は日付の形" 'case "${rep##*/}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md) true ;; *) false ;; esac'
check "結果に公開版の点検の節と当たった行を書く" 'grep -qx "## 公開版の点検" "$rep" && grep -Fq "\`$PUB_B\`: 業務の語が当たった（1行）" "$rep" && grep -Fqx "core/a.md:3:sample-term" "$rep" && ! grep -Fq "\`$PUB_A\`" "$rep"'
check "公開版のファイルは直さない" '[ "$(ls -A "$PUB_B")" = "rc" ]'

echo 2 >"$PUB_B/rc"
bash "$CP" >/dev/null 2>&1
rc=$?
rep2="$(ls -1t "$RD/"*.md | head -1)"
check "検査器の失敗（終了コード2）も結果に書き、同じ日は連番で別のファイルにする" '[ "$rc" -eq 1 ] && [ "$rep2" != "$rep" ] && grep -Fq "検査器が失敗した（終了コード 2）" "$rep2" && grep -Fq "一覧が空です" "$rep2"'

rm -rf "$RD"
printf '%s\n' "$WORK/no-such-public" >"$SKILL_AUDIT_PUBLIC_DIRS"
bash "$CP" >/dev/null 2>&1
check "一覧のディレクトリが無ければ結果に書く" 'grep -Fq "\`$WORK/no-such-public\`: ディレクトリが存在しない" "$RD/"*.md'

rm -rf "$RD"
printf '%s\n' "$PUB_A" >"$SKILL_AUDIT_PUBLIC_DIRS"
PUBLIC_CHECK_DIR="$WORK/no-such-checker" bash "$CP" >/dev/null 2>&1
rc=$?
check "検査器が無ければ、その旨を結果に書く" '[ "$rc" -eq 1 ] && grep -Fq "共通の検査器が見つからないため、点検をしていない" "$RD/"*.md'

rm -rf "$RD" "$STUB/args.log"
PUBLIC_CHECK_DIR= XDG_CONFIG_HOME="$WORK/xdg-empty" bash "$CP" >/dev/null 2>&1
rc=$?
check "検査器の場所が設定されていなければ、その旨を結果に書き点検を飛ばす" '[ "$rc" -eq 1 ] && grep -Fq "検査器の場所が設定されていない" "$RD/"*.md && [ ! -e "$STUB/args.log" ]'
rm -rf "$RD"
mkdir -p "$WORK/xdg/claude-skills"
printf '%s\n' "$STUB" >"$WORK/xdg/claude-skills/public-check-dir"
PUBLIC_CHECK_DIR= XDG_CONFIG_HOME="$WORK/xdg" bash "$CP" >/dev/null 2>&1
rc=$?
check "public-check-dir の1行目から検査器の場所を読む" '[ "$rc" -eq 0 ] && [ "$(cat "$STUB/args.log")" = "$PUB_A" ]'

echo "== run-audit.sh から check-public.sh を呼ぶ"
rm -rf "$RD"
PUBLIC_CHECK_DIR="$WORK/no-such-checker" "$SCRIPT_DIR/run-audit.sh"
rc=$?
check "検査器が無くても精査は止めず、結果を書く" '[ "$rc" -eq 0 ] && grep -Fq "共通の検査器が見つからないため" "$RD/"*.md'
rm -rf "$RD"
"$SCRIPT_DIR/run-audit.sh" --dry-run >/dev/null
check "dry-run では点検しない" '[ ! -e "$RD" ]'
unset PUBLIC_CHECK_DIR CLAUDE_REPORTS_ROOT SKILL_AUDIT_PUBLIC_DIRS

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
