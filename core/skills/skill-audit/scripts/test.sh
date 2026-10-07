#!/bin/bash
# skill-audit scripts の検査。一時ディレクトリに偽の ROOT を作って実行する。実際の claude は起動しない。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/skill-audit-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
# 本物の HOME の下のスキル・案の置き場所・状態を探さないよう、HOME を一時ディレクトリにする。
export HOME="$WORK/home"
mkdir -p "$HOME/.claude" "$HOME/.claude2"

export SKILL_AUDIT_ROOT="$WORK/root"
export SKILL_AUDIT_STATE="$WORK/state"
export SKILL_AUDIT_EXCLUDE="synced plugins vendored"
unset XDG_CONFIG_HOME CLAUDE_REVIEW_DENY_READ SKILL_AUDIT_OWN_LINK_ROOTS
# 起動するコマンドは常に偽物にする（本物の claude を起動しない）。共通の設定ファイルは一時の場所を指す。
export CLAUDE_LAUNCHER=true
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
export CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude:$HOME/.claude2"
# 承認待ちの置き場所と台帳は一時ディレクトリにする。案を作るスクリプトはリポジトリの core のものを使う。
export CLAUDE_REVIEW_PROPOSALS="$WORK/proposals"
export CLAUDE_REVIEW_STATE="$WORK/review-state"
export CHANGE_REVIEW_SCRIPTS="$(cd "$SCRIPT_DIR/../../change-review/scripts" && pwd -P)"
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

echo "== run-audit.sh --dry-run（初回）"
printf 'CLAUDE_REVIEW_DENY_READ=~/sync-a\n' >"$CLAUDE_REVIEW_JOBS_CONF"
out="$("$SCRIPT_DIR/run-audit.sh" --dry-run)"
rc=$?
check "初回は終了コード0" '[ "$rc" -eq 0 ]'
has() { printf '%s' "$out" | grep -Fq -- "$1"; }
for rule in "Edit(/$R/**)" "Bash($SCRIPT_DIR/snapshot.sh:*)" "Bash($SCRIPT_DIR/trash-skill.sh:*)" \
  "Read(/$R/**)" "Read(/$HOME/.claude/**)" "Read(/$HOME/.claude2/**)" "'Skill'" \
  "Read(/$HOME/.config/claude-skills/skill-audit.local.md)" \
  "利用者の環境だけの決まりは $HOME/.config/claude-skills/skill-audit.local.md にある（無ければ飛ばす）。" \
  "Read(/$HOME/Library/CloudStorage/**)" "Read(/$HOME/sync-a/**)" "&& 'true' '-p'" \
  "Edit(/$R/synced/**)" "Edit(/$R/plugins/**)" "Edit(/$R/vendored/**)" \
  "Edit(/$R/.trash/**)" "Edit(/$R/linked/**)" "Edit(/$WORK/external/linked/**)" \
  "Edit(/$HOME/.agents/**)" "Edit(/$HOME/Documents/**)" "Edit(/$HOME/.claude2/CLAUDE.md)" \
  "Edit(/$HOME/.claude/CLAUDE.md)" "Edit(/$HOME/.claude2/settings.json)" "Edit(/$HOME/.claude/settings.json)" \
  "--disallowedTools" "'--model' 'opus' '--effort' 'low'" "cd '$R' &&" \
  "否認リストは $PDIR/rejections.md にある。始める前に読み、否認リストと同じ対象・同じ趣旨の修正・削除は行わない。" \
  "Read(/$PDIR/**)" "Edit(/$PDIR/**)" "Edit(/$CLAUDE_REVIEW_STATE/**)" \
  "Read(/$HF)" "Edit(/$HF)" "Read(/$HD/**)" "変更の記録は $HF に書く。直す前の複製は snapshot.sh が $HD/<日付>/ に置く。"; do
  check "dry-run の出力に含む: $rule" 'has "$rule"'
done
# snapshot.sh と trash-skill.sh は、実体・スキル置き場を経由したパス（両アカウント）・作業のフォルダからの相対パスの各形を許可する。
for sc in snapshot.sh trash-skill.sh; do
  for sp in "$SCRIPT_DIR/$sc" "$R/skill-audit/scripts/$sc" "$HOME/.claude2/skills/skill-audit/scripts/$sc" \
    "$HOME/.claude/skills/skill-audit/scripts/$sc" "skill-audit/scripts/$sc" "./skill-audit/scripts/$sc"; do
    check "dry-run の出力に含む: Bash($sp:*)" 'has "'"'"'Bash($sp:*)'"'"'"'
  done
done
check "依頼文に snapshot.sh と trash-skill.sh を呼ぶ絶対パスを入れる" 'has "複製は $R/skill-audit/scripts/snapshot.sh、スキルの削除は $R/skill-audit/scripts/trash-skill.sh を、この絶対パスのとおりに呼ぶ"'
allow_part="${out%%--disallowedTools*}"
check "許可側に除外ディレクトリの規則を含まない" '! printf "%s" "$allow_part" | grep -Fq "synced"'
check "許可側に範囲を付けない Read を含まない" '! printf "%s" "$allow_part" | grep -Fq "'"'"'Read'"'"'"'
check "許可側に任意のパスを読める Bash を含まない" '! printf "%s" "$allow_part" | grep -Eq "Bash\\((ls|grep|rg|stat|wc|cmp|diff|readlink):"'
check "許可側に承認待ちの置き場所と台帳の Edit を含まない" '! printf "%s" "$allow_part" | grep -Fq "Edit(/$PDIR" && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$CLAUDE_REVIEW_STATE"'
check "許可側に読み取りを拒否する場所の規則を含まない" '! printf "%s" "$allow_part" | grep -Eq "CloudStorage|sync-a"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
check "dry-run は last-hash を作らない" '[ ! -f "$SKILL_AUDIT_STATE/last-hash" ]'
check "dry-run はログを作らない" '[ -z "$(ls "$SKILL_AUDIT_STATE/logs")" ]'
check "lock が解放されている" '[ ! -d "$SKILL_AUDIT_STATE/lock" ]'

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

echo "== 追加は残し、修正・削除は戻して承認待ちにする"
mkdir -p "$R/gamma/ref"
echo "gamma" >"$R/gamma/SKILL.md"
echo "gamma ref" >"$R/gamma/ref/a.md"
printf '# スキルの変更履歴\n\n説明\n\n---\n\n## 2000-01-01 依頼\n\n- 古い記録\n' >"$HF"
printf 'beta\nline2\n' >"$R/beta/SKILL.md"
FAKE="$WORK/fake-claude"
cat >"$FAKE" <<'EOF2'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_ARGS"
bash -c "$FAKE_HOOK" || exit 9
exit "${FAKE_RC:-0}"
EOF2
chmod +x "$FAKE"
export FAKE_ARGS="$WORK/fake-args" SCRIPT_DIR R HF HD
HOOK='printf "added\n" >>"$R/alpha/SKILL.md" &&
printf "beta\nline2 changed\n" >"$R/beta/SKILL.md" &&
rm "$R/alpha/sub/ref.md" &&
echo new >"$R/alpha/new2.md" &&
mkdir -p "$R/delta" && echo delta >"$R/delta/SKILL.md" &&
echo "snap" >"$HD/2000-01-01/z.bak" &&
awk "{print} /^---\$/{print \"\"; print \"## 自動の記録（claude）\"}" "$HF" >"$R/h.tmp" && mv "$R/h.tmp" "$HF" &&
"$SCRIPT_DIR/trash-skill.sh" gamma >/dev/null'
alpha_before="$(cat "$R/alpha/SKILL.md")"
CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK="$HOOK" "$SCRIPT_DIR/run-audit.sh" --force
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "追加だけの変更は残る" '[ "$(cat "$R/alpha/SKILL.md")" = "${alpha_before}${NL}added" ]'
check "新しいファイルと新しいスキルは残る" '[ -f "$R/alpha/new2.md" ] && [ -f "$R/delta/SKILL.md" ]'
check "修正は実行前の版に戻る" '[ "$(cat "$R/beta/SKILL.md")" = "beta${NL}line2" ]'
check "削除されたファイルは戻る" '[ "$(cat "$R/alpha/sub/ref.md")" = "changed" ]'
check "削除されたスキルは戻る（.skill-audit-trash から）" '[ -f "$R/gamma/SKILL.md" ] && [ -f "$R/gamma/ref/a.md" ] && [ -z "$(ls -d "$R/.skill-audit-trash/"*-gamma 2>/dev/null)" ]'
check "history の下の変更は比べない" '[ -f "$HD/2000-01-01/z.bak" ]'
props="$(ls "$PDIR"/*.md 2>/dev/null)"
printf '%s\n' "$props"
check "承認待ちは3件（修正・ファイルの削除・スキルの削除）" '[ "$(printf "%s\n" "$props" | grep -c .)" = "3" ]'
p_edit="$(grep -l "^  - $R/beta/SKILL.md\$" $props)"
p_file="$(grep -l "^  - $R/alpha/sub/ref.md\$" $props)"
p_skill="$(grep -l "^  - $R/gamma\$" $props)"
check "修正の案: 差分は実行前から実行後へ、見出しは絶対パス" '[ -f "$p_edit" ] && grep -Fxq -- "--- $R/beta/SKILL.md" "$p_edit" && grep -Fxq -- "-line2" "$p_edit" && grep -Fxq "+line2 changed" "$p_edit" && grep -Fxq "status: pending" "$p_edit" && grep -q "^source: skill-audit（自動の精査 " "$p_edit"'
check "ファイルの削除の案" '[ -f "$p_file" ] && grep -Fxq -- "-changed" "$p_file" && grep -q "の削除（skill-audit の自動の精査）" "$p_file"'
check "スキルの削除の案: 全ファイルの削除差分と trash-skill.sh の案内" '[ -f "$p_skill" ] && grep -Fxq -- "--- $R/gamma/SKILL.md" "$p_skill" && grep -Fxq -- "--- $R/gamma/ref/a.md" "$p_skill" && grep -Fxq -- "-gamma ref" "$p_skill" && grep -Fq "trash-skill.sh gamma" "$p_skill"'
hist="$(cat "$HF")"
check "history.md の先頭に記録を足す（claude の追記も残る）" 'printf "%s" "$hist" | grep -q "自動（run-audit.sh の記録）" && printf "%s" "$hist" | grep -Fq "## 自動の記録（claude）" && [ "$(printf "%s\n" "$hist" | grep -n "run-audit.sh の記録" | cut -d: -f1)" -lt "$(printf "%s\n" "$hist" | grep -n "2000-01-01 依頼" | cut -d: -f1)" ]'
check "history.md に件数と番号を書く" 'printf "%s" "$hist" | grep -Fq -- "- 承認待ちにした変更: 3件（" && printf "%s" "$hist" | grep -Fq -- "\`$R/alpha/new2.md\`（新しいファイル）" && printf "%s" "$hist" | grep -Fq -- "\`$R/delta\`（新しいスキル）"'
check "冒頭の説明は残る" '[ "$(head -1 "$HF")" = "# スキルの変更履歴" ]'
check "実行前の複製を runs に残す" '[ -f "$(ls -d "$SKILL_AUDIT_STATE/runs/"*/ | tail -1)before/beta/SKILL.md" ]'
check "台帳には書かない" '[ ! -e "$CLAUDE_REVIEW_STATE/decisions.jsonl" ]'
rm -rf "$R/delta" "$R/gamma" "$R/alpha/new2.md" "$HF"

echo "== スキルの削除と参照の修正を1件にまとめ、行き先の表を付ける"
mkdir -p "$R/eps"
printf 'eps 決まり\n' >"$R/eps/SKILL.md"
printf 'beta\nline2\n- eps を使う\n' >"$R/beta/SKILL.md"
printf '# 規則\n\n- 既存\n' >"$HOME/.claude/CLAUDE.md"
alpha_before="$(cat "$R/alpha/SKILL.md")"
ls "$PDIR"/*.md | sort >"$WORK/props-before"
export HOME
HOOK_DEST='DEST="$(grep -o "[^ ]*/destinations の下のフォルダに書く" "$FAKE_ARGS" | head -1)"; DEST="${DEST%% の下*}" &&
D="$DEST$R/eps" && mkdir -p "$D" &&
"$SCRIPT_DIR/trash-skill.sh" eps >/dev/null &&
printf "beta\nline2\n" >"$R/beta/SKILL.md" &&
printf "added directly\n" >>"$R/alpha/SKILL.md" &&
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | eps の決まり | 記載なし → この案で移す | 移し先 \`$HOME/.claude/CLAUDE.md\`（規則） |\n| 2 | eps の索引 | 記載なし → この案で移す | 移し先 \`$R/alpha/SKILL.md\`（末尾） |\n" >"$D/table.md" &&
printf "# 規則\n\n- 既存\n- eps の決まり\n" >"$D/CLAUDE.md" &&
{ cat "$R/alpha/SKILL.md" | sed "\$d"; printf "eps の索引\n"; } >"$D/alpha.md" &&
printf "%s\t%s\n" "$HOME/.claude/CLAUDE.md" CLAUDE.md "$R/alpha/SKILL.md" alpha.md >"$D/moves.tsv"'
CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK="$HOOK_DEST" "$SCRIPT_DIR/run-audit.sh" --force
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "依頼文に行き先の表の書き方と、参照の修正をまとめることを含む" 'grep -Fq "| No | 消える記述 | 行き先 | 場所 |" "$FAKE_ARGS" && grep -Fq "そのスキルを参照する他の箇所の修正も同じ実行の中で行う" "$FAKE_ARGS"'
check "行き先のフォルダへの書き込みを許可する" 'grep -q "^Edit(/.*/destinations/\*\*)$" "$FAKE_ARGS"'
new_props="$(ls "$PDIR"/*.md | sort | comm -13 "$WORK/props-before" -)"
printf '%s\n' "$new_props"
check "承認待ちは1件だけ増える（参照の修正を別の案にしない）" '[ "$(printf "%s\n" "$new_props" | grep -c .)" = "1" ]'
p_eps="$new_props"
check "スキルの削除の案に参照の修正の差分が入る" 'grep -Fxq "  - $R/eps" "$p_eps" && grep -Fxq "  - $R/beta/SKILL.md" "$p_eps" && grep -Fxq -- "--- $R/beta/SKILL.md" "$p_eps" && grep -Fxq -- "-- eps を使う" "$p_eps"'
check "スキルの削除の案に行き先の表と移し先への追加の差分が入る" 'grep -Fxq "## 消える記述の行き先" "$p_eps" && grep -Fq "| 1 | eps の決まり | 記載なし → この案で移す |" "$p_eps" && grep -Fxq "  - $HOME/.claude/CLAUDE.md" "$p_eps" && grep -Fxq "+- eps の決まり" "$p_eps" && grep -Fxq "+eps の索引" "$p_eps" && grep -q "^# eps の削除（skill-audit の自動の精査）$" "$p_eps"'
check "削除したスキルと参照の修正は戻る" '[ -f "$R/eps/SKILL.md" ] && [ "$(cat "$R/beta/SKILL.md")" = "beta${NL}line2${NL}- eps を使う" ]'
check "移し先へは自動で書き足さない" '[ "$(cat "$HOME/.claude/CLAUDE.md")" = "# 規則${NL}${NL}- 既存" ]'
check "移し先を直接書き換えていたら戻す" '[ "$(cat "$R/alpha/SKILL.md")" = "$alpha_before" ] && grep -Fq "$R/alpha/SKILL.md\`: 行き先の表の移し先を直接書き換えていた" "$HF"'
rm -rf "$R/eps" "$HF"
printf 'beta\nline2\n' >"$R/beta/SKILL.md"

echo "== change-review が見つからなくても修正は戻す"
printf "beta\nline2\n" >"$R/beta/SKILL.md"
n_before="$(ls "$PDIR" | wc -l | tr -d " ")"
# core/skills の中では隣に change-review があるため、隣に何も無い場所へ複製した scripts で試す。
mkdir -p "$WORK/isolated/skill-audit" && cp -Rp "$SCRIPT_DIR" "$WORK/isolated/skill-audit/scripts"
CHANGE_REVIEW_SCRIPTS="$WORK/nosuch" CLAUDE_LAUNCHER="$FAKE" FAKE_HOOK='echo x >"$R/beta/SKILL.md"' "$WORK/isolated/skill-audit/scripts/run-audit.sh" --force
check "修正は戻る" '[ "$(cat "$R/beta/SKILL.md")" = "beta${NL}line2" ]'
check "承認待ちは増えない" '[ "$(ls "$PDIR" | wc -l | tr -d " ")" = "$n_before" ]'
check "history.md に作れなかったことを書く" 'grep -Fq "Skill change-review が見つからず承認待ちを作れなかった" "$HF"'
check "history.md が無ければ冒頭の説明と区切りを作る" '[ "$(head -1 "$HF")" = "# スキルの変更履歴" ] && grep -qx -- "---" "$HF"'
check "スキル置き場に history を作らない" '[ ! -e "$R/skill-audit/history.md" ] && [ ! -e "$R/skill-audit/history" ]'
rm -f "$HF"
# 後片付けの後の状態で last-hash を取り直す。
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
check "設定ファイルの設定ディレクトリだけを使う" '! printf "%s" "$out" | grep -Fq ".claude2"'
out="$(CLAUDE_LAUNCHER=/opt/env-launcher "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "環境変数が設定ファイルより優先する" 'printf "%s" "$out" | grep -Fq "&& '"'"'/opt/env-launcher'"'"' '"'"'-p'"'"'"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u SKILL_AUDIT_EXCLUDE "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "除外の指定が無ければ名前で除外しない" '! printf "%s" "$out" | grep -Fq "Edit(/$R/plugins/**)"'
printf 'SKILL_AUDIT_ROOT=%s\nSKILL_AUDIT_EXCLUDE=plugins\n' "$R" >"$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u SKILL_AUDIT_ROOT -u SKILL_AUDIT_EXCLUDE "$SCRIPT_DIR/run-audit.sh" --dry-run --force)"
check "設定ファイルの ROOT と除外の名前を使う" 'printf "%s" "$out" | grep -Fq "cd '"'"'$R'"'"' &&" && printf "%s" "$out" | grep -Fq "Edit(/$R/plugins/**)" && ! printf "%s" "$out" | grep -Fq "Edit(/$R/vendored/**)"'
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

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
