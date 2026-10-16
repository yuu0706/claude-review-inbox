#!/bin/bash
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
# 承認待ちの案を作るスクリプトは、リポジトリの core のものを使う。
CR_REAL="$(cd "$SCRIPT_DIR/../../change-review/scripts" && pwd -P)"
export CHANGE_REVIEW_SCRIPTS="$CR_REAL"
# 承認なし（auto）の動きを既定として検査する。承認あり（screen）は末尾で別に確かめる。変更の台帳は一時の場所に置く。
export CLAUDE_REVIEW_APPROVAL_MODE=auto
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

echo "== --dry-run"
out="$("$SCRIPT_DIR/run.sh" --dry-run)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
printf '%s\n' "$out" | grep '^TARGET'
check "対象は memory を持つ2件だけ" '[ "$(printf "%s\n" "$out" | grep -c "^TARGET: ")" = "2" ]'
has() { printf '%s' "$out" | grep -Fq -- "$1"; }
day="$(date '+%Y-%m-%d')"
for rule in "'$FAKE' '-p'" "Skill memory-audit を自動モードで実行する。対象のメモリは ${M_A} ${M_C}、直す前の複製は ${RDIR}/.snapshots/" \
  "、直した版の書き込み先は ${RDIR}/.staging/" \
  "（元の絶対パスの構造を保ち、.claude で始まる要素は先頭のドットを外して写す）、レポートの出力先は ${RDIR}/${day}.md。" \
  "対象ごとの元の位置と書き込み先での位置は次のとおり: ${M_A} → ${RDIR}/.staging/" "${S_A}、${M_C} → ${RDIR}/.staging/" \
  "${S_C}。メモリは直接直さず、書き込み先へ直した版を書く。" "'--model' 'opus' '--effort' 'low'" \
  "'--allowedTools' 'Skill' 'Bash(which:*)' 'Read(/$HOME/.claude/**)'" "'Read(/$PDIR/**)' 'Read(/$HOME/.config/claude-skills/memory-audit.local.md)' 'Edit(/$RDIR/.staging/" \
  "/**)' 'Edit(/$RDIR/*.md)' '--disallowedTools'" "'Edit(/$RDIR/.snapshots/**)'" \
  "否認リストは $PDIR/rejections.md にある。始める前に読み、否認リストと同じ対象・同じ趣旨の修正・削除は作らない。" \
  "/deletions.tsv に「元の絶対パス<TAB>理由」の形で1行1件書く。" \
  "'Edit(/$HOME/Documents/**)' 'Edit(/$PDIR/**)' 'Edit(/$LEDGER/**)'" \
  "'Edit(/$HOME/.claude/CLAUDE.md)' 'Edit(/$HOME/.claude/settings.json)' 'Edit(/$HOME/.claude/skills/**)'" \
  "'Edit(/$HOME/${ALT_DIR}/CLAUDE.md)' 'Edit(/$HOME/${ALT_DIR}/settings.json)' 'Edit(/$HOME/${ALT_DIR}/skills/**)'" \
  "'Read(/$HOME/.claude/**)' 'Read(/$HOME/${ALT_DIR}/**)'" \
  "'Read(/$HOME/.config/claude-skills/memory-audit.local.md)'" \
  "利用者の環境だけの決まりは $HOME/.config/claude-skills/memory-audit.local.md にある（無ければ飛ばす）。" \
  "'--disallowedTools' 'Read(/$HOME/Library/CloudStorage/**)' 'Edit(/$RDIR/.snapshots/**)'" \
  "'Edit(/$M_A/**)' 'Edit(/$M_C/**)'" "cd '$RDIR' &&"; do
  check "dry-run の出力に含む: $rule" 'has "$rule"'
done
allow_part="$(printf '%s' "$out" | sed -n "s/.*'--allowedTools'\(.*\)'--disallowedTools'.*/\1/p")"
mapped="$(printf '%s' "$out" | sed -n 's/.*次のとおり: \(.*\)。メモリは直接直さず.*/\1/p' | grep -o "→ [^、。]*" | sed 's/^→ //')"
check "対応の一覧は2件" '[ "$(printf "%s\n" "$mapped" | grep -c .)" = "2" ]'
check "対応の一覧の写した先に .claude で始まる要素が無い" '! printf "%s\n" "$mapped" | grep -q "/\.claude"'
check "メモリのディレクトリの Edit を許可しない" '[ -n "$allow_part" ] && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$M_A/**)" && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$M_C/**)"'
check "許可側に範囲を付けない Read を含まない" '! printf "%s" "$allow_part" | grep -Fq "'"'"'Read'"'"'"'
check "承認待ちの置き場所と台帳の Edit を許可しない" '! printf "%s" "$allow_part" | grep -Fq "Edit(/$PDIR" && ! printf "%s" "$allow_part" | grep -Fq "Edit(/$LEDGER"'
check "許可の Edit は .staging とレポートの2件だけ" '[ "$(printf "%s" "$allow_part" | grep -o "Edit(" | wc -l | tr -d " ")" = "2" ]'
check "rm・mv・aws・curl を許可しない" '! has "Bash(rm" && ! has "Bash(mv" && ! has "Bash(aws" && ! has "Bash(curl"'
check "dry-run は複製しない" '[ -z "$(ls "$RDIR/.snapshots")" ] && [ -z "$(ls "$RDIR/.staging")" ]'
check "dry-run はレポートを作らない" '[ -z "$(ls "$RDIR"/*.md 2>/dev/null)" ]'
check "lock が解放されている" '[ ! -d "$STATE/lock" ]'

echo "== 通常実行（直した版を .staging へ書く偽の claude）"
# 正常系1件に加え、書き戻してはならないものを .staging へ置く。
mkdir -p "$HOME/outside"
echo "o1" >"$HOME/outside/o.md"
echo "x1" >"$M_A/x..y.md"
echo "t1" >"$M_A/t.txt"
echo "l1" >"$M_A/l.md"
echo d1 >"$M_A/d.md"
echo e1 >"$M_C/e.md"
HOOK_MAIN='mkdir -p "$STAGE$S_A" "$STAGE$S_C/sub" "$STAGE$HOME/outside" "$STAGE$M_A" &&
printf "a1\na2\n" >"$STAGE$S_A/a.md" &&
printf "%s\t%s\n" "$M_A/d.md" "e.md と重複" "$HOME/outside/o.md" "範囲外" "$M_A/nosuch.md" "無い" "$M_A/../proj-a/memory/l.md" "相対" >"$STAGE/deletions.tsv" &&
printf "%s\t%s\n" "$M_C/e.md" "判断に迷う" "$M_A/d.md" "統合先の確認が要る" >"$STAGE/needs-approval.tsv" &&
echo e2 >"$STAGE$S_C/e.md" &&
echo n1 >"$STAGE$S_A/new.md" &&
echo t2 >"$STAGE$S_A/t.txt" &&
echo x2 >"$STAGE$S_A/x..y.md" &&
echo c2 >"$STAGE$S_C/sub/c.md" &&
echo o2 >"$STAGE$HOME/outside/o.md" &&
echo d2 >"$STAGE$M_A/d.md" &&
echo l2 >"$WORK/link-src.md" && ln -s "$WORK/link-src.md" "$STAGE$S_A/l.md"'
export M_A M_C S_A S_C WORK
FAKE_HOOK="$HOOK_MAIN" "$SCRIPT_DIR/run.sh"
rc=$?
rep="$RDIR/$day.md"
snap="$(ls -d "$RDIR/.snapshots/"*/ | head -1)"; snap="${snap%/}"
stage="$(ls -d "$RDIR/.staging/"*/ | head -1)"; stage="${stage%/}"
check "終了コード0" '[ "$rc" -eq 0 ]'
check ".snapshots に元のパスを保って複製される" '[ "$(cat "$snap$M_A/a.md")" = "a1" ] && [ -f "$snap$M_C/sub/c.md" ]'
check "複製は属性を保つ（更新日時が同じ）" '[ "$(stat -f %m "$snap$M_C/sub/c.md")" = "$(stat -f %m "$M_C/sub/c.md")" ]'
check ".snapshots と .staging は同じ日時の名前" '[ "${snap##*/}" = "${stage##*/}" ]'
check "CLAUDE_LAUNCHER のコマンドで起動される" 'grep -Fxq -- "--disallowedTools" "$FAKE_ARGS"'
check "追加だけの変更: .claude の対象へ書き戻される" '[ "$(cat "$M_A/a.md")" = "a1${NL}a2" ]'
check "既存の行を変える修正: 書き戻さない" '[ "$(cat "$M_C/e.md")" = "e1" ]'
props="$(ls "$PDIR"/*.md 2>/dev/null | grep -v rejections)"
echo "$props"
check "承認待ちは2件（修正1件・削除1件）" '[ "$(printf "%s\n" "$props" | grep -c .)" = "2" ]'
p_edit="$(grep -l "^  - $M_C/e.md\$" $props)"
p_del="$(grep -l "^  - $M_A/d.md\$" $props)"
check "修正の案: frontmatter" '[ -f "$p_edit" ] && grep -Fxq "status: pending" "$p_edit" && grep -q "^source: memory-audit（$RDIR/$day.md）$" "$p_edit" && grep -q "^id: $day-0[12]$" "$p_edit"'
check "修正の案: 見出しの2行は元の絶対パス、差分は -e1 +e2" 'grep -Fxq -- "--- $M_C/e.md" "$p_edit" && grep -Fxq "+++ $M_C/e.md" "$p_edit" && grep -Fxq -- "-e1" "$p_edit" && grep -Fxq "+e2" "$p_edit" && grep -q "^# メモリ proj-c/e.md の修正（memory-audit の精査）（移し先の確認が必要）$" "$p_edit" && grep -Fq "行き先の表が作られなかった" "$p_edit"'
check "削除の案: 差分は -d1 だけで、理由を載せる" '[ -f "$p_del" ] && grep -Fxq -- "-d1" "$p_del" && ! grep -q "^+[^+]" "$p_del" && grep -q "e.md と重複" "$p_del" && grep -q "の削除（memory-audit の精査）" "$p_del"'
check "削除の候補のファイルは消さない" '[ "$(cat "$M_A/d.md")" = "d1" ]'
check "案の名前は <日付>-<連番>-<短い名前>.md" '[[ "${p_del##*/}" =~ ^$day-0[12]-memory-audit-delete\.md$ ]] && [[ "${p_edit##*/}" =~ ^$day-0[12]-memory-audit-edit\.md$ ]]'
check "台帳には書かない" '[ ! -e "$LEDGER/decisions.jsonl" ]'
check "書き戻しは属性を保つ（更新日時が同じ）" '[ "$(stat -f %m "$M_A/a.md")" = "$(stat -f %m "$stage$S_A/a.md")" ]'
check "元の絶対パスのまま写したファイルは書き戻さない" '[ "$(cat "$M_A/d.md")" = "d1" ]'
check "新しいファイルを作らない" '[ ! -e "$M_A/new.md" ]'
check ".md 以外を書き戻さない" '[ "$(cat "$M_A/t.txt")" = "t1" ]'
check ".. を含むパスを書き戻さない" '[ "$(cat "$M_A/x..y.md")" = "x1" ]'
check "直下でないファイルを書き戻さない" '[ "$(cat "$M_C/sub/c.md")" = "c1" ]'
check "対象外の場所を書き戻さない" '[ "$(cat "$HOME/outside/o.md")" = "o1" ]'
check "リンクを書き戻さない" '[ ! -L "$M_A/l.md" ] && [ "$(cat "$M_A/l.md")" = "l1" ]'
check "作業用のフォルダを消さない" '[ -f "$stage$S_A/new.md" ]'
# 偽の claude が元の絶対パスのまま書いた $HOME/.claude は検査から外す。
check "写した先に .claude で始まる要素が無い" '[ -z "$(cd "$stage" && find . -path "./${HOME#/}/.claude" -prune -o -name ".claude*" -print)" ] && [ -f "$stage$S_C/e.md" ]'
cat "$rep"
check "レポートの本文が残る" 'grep -Fq "検査用" "$rep"'
skipped="$(awk '/^## 書き戻さなかったファイル/{f=1;next} /^## /{f=0} f' "$rep")"
for item in "$HOME/outside/o.md\`: 削除の候補だが" "$M_A/nosuch.md\`: 削除の候補だが" "$M_A/../proj-a/memory/l.md\`: 削除の候補だが" \
  "$M_A/new.md\`: 元の場所に同名のファイルが無い" "$M_A/t.txt\`: 拡張子が .md ではない" \
  "$M_A/x..y.md\`: パスに .. を含む" "$stage$S_C/sub/c.md\`: 対象のメモリのディレクトリの直下ではない" \
  "$stage$HOME/outside/o.md\`: 対象のメモリのディレクトリの直下ではない" "$M_A/l.md\`: シンボリックリンクである" \
  "$stage$M_A/d.md\`: 対象のメモリのディレクトリの直下ではない"; do
  check "書き戻さなかったファイルに理由付きで載る: ${item#$WORK/}" 'printf "%s" "$skipped" | grep -Fq -- "$item"'
done
check "deletions.tsv と needs-approval.tsv は書き戻しの対象として載せない" '! printf "%s" "$skipped" | grep -Fq "deletions.tsv" && ! printf "%s" "$skipped" | grep -Fq "needs-approval.tsv"'
check "承認待ちの理由に精査の判断を載せる" 'grep -Fq "精査が承認が要ると判断した（判断に迷う）" "$p_edit" && grep -Fq "精査が承認が要ると判断した（統合先の確認が要る）" "$p_del"'
summary="$(awk '/^## 承認なしで反映した変更と承認待ち/{f=1;next} /^## /{f=0} f' "$rep")"
check "レポートに件数と番号を書く" 'printf "%s" "$summary" | grep -Fq "承認なしで反映した変更 1件 / 承認待ちにした 2件（$day-01、$day-02）"'
check "レポートに反映した変更（ID・種類・直す前の版）と承認待ちの一覧を書く" 'printf "%s" "$summary" | grep -Eq -- "^- memory-audit-${stage##*/}-01: \`$M_A/a.md\`（追加。種類 \`memory-audit/追加/proj-a/a.md\`。直す前の版 \`$snap$M_A/a.md\`）$" && printf "%s" "$summary" | grep -Fq "\`$M_C/e.md\`（修正）" && printf "%s" "$summary" | grep -Fq "\`$M_A/d.md\`（削除）"'
check "レポートに訂正の手順と訂正リストの場所を書く" 'printf "%s" "$summary" | grep -Fq "訂正リスト（$PDIR/corrections.md）"'
check "書き戻したファイルは載らない" '! printf "%s" "$skipped" | grep -Fq "$M_A/a.md" && ! printf "%s" "$skipped" | grep -Fq "$M_C/e.md"'
check "末尾に変更の差分がある" 'grep -Fxq "## 変更の差分" "$rep" && grep -Fxq "+a2" "$rep" && ! grep -Fxq "+e2" "$rep"'
check "差分の節は書き戻しの節より後" '[ "$(grep -n "^## 変更の差分" "$rep" | cut -d: -f1)" -gt "$(grep -n "^## 書き戻さなかったファイル" "$rep" | cut -d: -f1)" ]'

echo "== 変更が無い場合"
sleep 1
"$SCRIPT_DIR/run.sh"
rep2="$RDIR/$day-2.md"
check "同日2回目は連番" '[ -f "$rep2" ]'
check "書き戻さなかったファイルが無ければ「なし」" 'awk "/^## 書き戻さなかったファイル/{f=1;next} /^## /{f=0} f" "$rep2" | grep -Fxq "なし"'
check "差分が無ければ「変更なし」" 'awk "/^## 変更の差分/{f=1} f" "$rep2" | grep -Fxq "変更なし"'
check "複製は2回分" '[ "$(ls "$RDIR/.snapshots" | wc -l | tr -d " ")" = "2" ] && [ "$(ls "$RDIR/.staging" | wc -l | tr -d " ")" = "2" ]'

echo "== claude が失敗したら書き戻さない"
sleep 1
FAKE_RC=3 FAKE_HOOK='mkdir -p "$STAGE$S_A" && echo a3 >"$STAGE$S_A/a.md"' "$SCRIPT_DIR/run.sh"
rc=$?
check "終了コードを引き継ぐ（rc=${rc}）" '[ "$rc" -eq 3 ]'
check "書き戻さない" '[ "$(cat "$M_A/a.md")" = "a1${NL}a2" ]'
check "承認待ちも作らない" '[ "$(ls "$PDIR" | grep -vc rejections)" = "2" ]'
check "書き戻さなかった理由がある" 'grep -Fq "精査が異常終了したため（終了コード 3）" "$RDIR/$day-3.md"'
check "差分の節がある" 'grep -Fxq "## 変更の差分" "$RDIR/$day-3.md" && grep -Fxq "変更なし" "$RDIR/$day-3.md"'
sleep 1
CLAUDE_LAUNCHER=true "$SCRIPT_DIR/run.sh"
check "レポートが作られなければ見出しを補う" 'grep -Fq "レポートが作られませんでした" "$RDIR/$day-4.md" && grep -Fxq "変更なし" "$RDIR/$day-4.md"'

echo "== change-review が見つからなければ、修正を書き戻さず承認待ちも作らない"
sleep 1
# core/skills の中では隣に change-review があるため、隣に書き換えを拒否する規則の部品（link-scopes.sh）だけを置いた場所へ
# 複製した scripts で試す。
mkdir -p "$WORK/isolated/memory-audit" "$WORK/isolated/change-review/scripts" && cp -Rp "$SCRIPT_DIR" "$WORK/isolated/memory-audit/scripts"
cp -p "$CR_REAL/link-scopes.sh" "$WORK/isolated/change-review/scripts/"
CHANGE_REVIEW_SCRIPTS="$WORK/nosuch" FAKE_HOOK='mkdir -p "$STAGE$S_C" && echo e3 >"$STAGE$S_C/e.md"' "$WORK/isolated/memory-audit/scripts/run.sh"
rep5="$(ls -t "$RDIR"/*.md | head -1)"
check "書き戻さない" '[ "$(cat "$M_C/e.md")" = "e1" ]'
check "理由を書く" 'grep -Fq "$M_C/e.md\`: 既存の行を変える修正だが、Skill change-review が見つからず" "$rep5"'
check "承認待ちは増えない" '[ "$(ls "$PDIR" | grep -vc rejections)" = "2" ]'

echo "== 書き換えを拒否する規則の部品（link-scopes.sh）が無ければ起動しない"
sleep 1
mkdir -p "$WORK/bare/memory-audit" && cp -Rp "$SCRIPT_DIR" "$WORK/bare/memory-audit/scripts"
rm -f "$FAKE_ARGS"
CHANGE_REVIEW_SCRIPTS="$WORK/nosuch" "$WORK/bare/memory-audit/scripts/run.sh"
rc=$?
check "終了コード1（rc=${rc}）" '[ "$rc" -eq 1 ]'
check "claude を起動しない" '[ ! -f "$FAKE_ARGS" ]'
check "ログに理由が書かれる" 'grep -q "link-scopes.sh を読み込めません" "$(ls -1t "$STATE/logs/"*.log | head -1)"'

echo "== 複製に失敗したら起動しない"
sleep 1
rm -f "$FAKE_ARGS"
chmod 000 "$M_C/sub"
"$SCRIPT_DIR/run.sh"
rc=$?
chmod 755 "$M_C/sub"
check "終了コード1（rc=${rc}）" '[ "$rc" -eq 1 ]'
check "claude を起動しない" '[ ! -f "$FAKE_ARGS" ]'
log1="$(ls -1t "$STATE/logs/"*.log | head -1)"
check "ログに理由が書かれる" 'grep -q "複製に失敗しました" "$log1"'

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

echo "== 消える記述の行き先と、索引の行の削除"
printf 'g1 決まり\ng2 経緯\n' >"$M_A/g.md"
printf 'h1\nh2\n' >"$M_A/h.md"
printf -- '- [G](g.md) — g\n- [A](a.md) — a\n' >"$M_A/MEMORY.md"
printf '# 規則\n\n- 既存\n' >"$HOME/.claude/CLAUDE.md"
n_before="$(ls "$PDIR" | grep -vc rejections)"
HOOK_DEST='mkdir -p "$STAGE$S_A" "$STAGE/destinations$S_A/g.md" "$STAGE/destinations$S_A/h.md" &&
printf "%s\t%s\n" "$M_A/g.md" "CLAUDE.md へ移す" >"$STAGE/deletions.tsv" &&
printf -- "- [A](a.md) — a\n- [N](n.md) — n\n" >"$STAGE$S_A/MEMORY.md" &&
printf "h1\n" >"$STAGE$S_A/h.md" &&
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | g1 の決まり | 記載なし → この案で移す | 移し先 \`$HOME/.claude/CLAUDE.md\`（規則） |\n| 2 | g2 の経緯 | 決まりではない（リンク・経緯の記録など） | — |\n" >"$STAGE/destinations$S_A/g.md/table.md" &&
printf "# 規則\n\n- 既存\n- g1 の決まり\n" >"$STAGE/destinations$S_A/g.md/CLAUDE.md" &&
printf "%s\t%s\n" "$HOME/.claude/CLAUDE.md" "CLAUDE.md" >"$STAGE/destinations$S_A/g.md/moves.tsv" &&
printf "| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | h2 の事実 | 記載なし → この案で移す | （候補なし） |\n" >"$STAGE/destinations$S_A/h.md/table.md"'
sleep 1
FAKE_HOOK="$HOOK_DEST" "$SCRIPT_DIR/run.sh"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "依頼文に行き先の表の書き方を含む" 'grep -Fq "| No | 消える記述 | 行き先 | 場所 |" "$FAKE_ARGS" && grep -Fq "/destinations の下のフォルダに書く" "$FAKE_ARGS" && grep -Fq "索引（MEMORY.md）の行は消さない" "$FAKE_ARGS"'
new_props="$(ls -t "$PDIR"/*.md | grep -v rejections | head -n $(( $(ls "$PDIR" | grep -vc rejections) - n_before )))"
echo "$new_props"
check "承認待ちは2件だけ増える（索引だけの案を作らない）" '[ "$(printf "%s\n" "$new_props" | grep -c .)" = "2" ]'
p_g="$(grep -l "^  - $M_A/g.md\$" $new_props)"
p_h="$(grep -l "^  - $M_A/h.md\$" $new_props)"
check "索引の行の削除はメモリの削除の案に入る" '[ -f "$p_g" ] && grep -Fxq "  - $M_A/MEMORY.md" "$p_g" && grep -Fxq -- "--- $M_A/MEMORY.md" "$p_g" && grep -Fxq -- "-- [G](g.md) — g" "$p_g"'
check "索引の修正の案は別に作らない" '! grep -l "^# メモリ proj-a/MEMORY.md" $new_props'
check "索引への追加は書き戻し、削除の候補の行は残す" '[ "$(cat "$M_A/MEMORY.md")" = "- [G](g.md) — g${NL}- [A](a.md) — a${NL}- [N](n.md) — n" ]'
check "削除の案に行き先の表が入る" 'grep -Fxq "## 消える記述の行き先" "$p_g" && grep -Fq "| 1 | g1 の決まり | 記載なし → この案で移す | 移し先 \`$HOME/.claude/CLAUDE.md\`（規則） |" "$p_g" && grep -Fq "| 3 | 索引 MEMORY.md の、このメモリを指す行 |" "$p_g" && grep -Fq "「No 3 は移さない」" "$p_g"'
check "行き先の表は理由の後、差分の前" '[ "$(grep -n "^## 理由" "$p_g" | cut -d: -f1)" -lt "$(grep -n "^## 消える記述の行き先" "$p_g" | cut -d: -f1)" ] && [ "$(grep -n "^## 消える記述の行き先" "$p_g" | cut -d: -f1)" -lt "$(grep -n "^## 差分" "$p_g" | cut -d: -f1)" ]'
check "「記載なし」の移し先への追加の差分が同じ案に入る" 'grep -Fxq "  - $HOME/.claude/CLAUDE.md" "$p_g" && grep -Fxq -- "--- $HOME/.claude/CLAUDE.md" "$p_g" && grep -Fxq "+- g1 の決まり" "$p_g"'
check "移し先がそろっていれば確認の印を付けない" 'grep -q "^# メモリ proj-a/g.md の削除（memory-audit の精査）$" "$p_g" && ! grep -Fq "移し先の確認が必要な点" "$p_g"'
check "移し先へは自動で書き足さない" '[ "$(cat "$HOME/.claude/CLAUDE.md")" = "# 規則${NL}${NL}- 既存" ]'
check "削除の候補のファイルは消さない" '[ -f "$M_A/g.md" ]'
check "移し先の候補が無ければ見出しに確認の印を付ける" '[ -f "$p_h" ] && grep -q "^# メモリ proj-a/h.md の修正（memory-audit の精査）（移し先の確認が必要）$" "$p_h" && grep -Fq "No 1: 移し先の候補が無い" "$p_h" && grep -Fxq "status: pending" "$p_h"'

echo "== 承認が要らない修正と削除は反映し、ID と直す前の版を載せる"
printf 'p1\np2\n' >"$M_A/p.md"
printf 'q1\n' >"$M_A/q.md"
printf 'r1 permissions.deny で止める\nr2\n' >"$M_A/r.md"
printf 's1\n' >"$M_A/s.md"
printf -- '- [A](a.md) — a\n- [Q](q.md) — q\n' >"$M_A/MEMORY.md"
# s.md の修正は、同じ種類が2回訂正されているため承認待ちに回る。
bash "$CR_REAL/corrections.sh" add --id memory-audit-2000-01-01-000000-01 --kind memory-audit/修正/proj-a/s.md --target "$M_A/s.md" --correct "正しくは s1 のまま残す" >/dev/null
bash "$CR_REAL/corrections.sh" add --id memory-audit-2000-01-08-000000-01 --kind memory-audit/修正/proj-a/s.md --target "$M_A/s.md" --correct "正しくは s1 を消さない" >/dev/null
n_before="$(ls "$PDIR" | grep -vc -e rejections -e corrections)"
HOOK_AUTO='mkdir -p "$STAGE$S_A" &&
printf "p1 直した\np2\n" >"$STAGE$S_A/p.md" &&
printf "r2\n" >"$STAGE$S_A/r.md" &&
printf "s2\n" >"$STAGE$S_A/s.md" &&
printf "%s\t%s\n" "$M_A/q.md" "p.md へ統合済み" >"$STAGE/deletions.tsv"'
sleep 1
FAKE_HOOK="$HOOK_AUTO" "$SCRIPT_DIR/run.sh"
rc=$?
rep6="$(ls -t "$RDIR"/*.md | head -1)"
snap6="$(ls -d "$RDIR/.snapshots/"*/ | LC_ALL=C sort | tail -1)"; snap6="${snap6%/}"
check "終了コード0" '[ "$rc" -eq 0 ]'
check "依頼文に訂正リストと needs-approval.tsv の書き方を含む" 'grep -Fq "訂正リストは $PDIR/corrections.md にある。" "$FAKE_ARGS" && grep -Fq "/needs-approval.tsv に「元の絶対パス<TAB>理由」の形で1行1件書く" "$FAKE_ARGS"'
check "承認の要らない修正は書き戻す" '[ "$(cat "$M_A/p.md")" = "p1 直した${NL}p2" ]'
check "承認の要らない削除はファイルを消す" '[ ! -e "$M_A/q.md" ]'
check "削除したメモリを指す索引の行も消す" '[ "$(cat "$M_A/MEMORY.md")" = "- [A](a.md) — a" ]'
check "直す前の版は .snapshots に残る" '[ "$(cat "$snap6$M_A/q.md")" = "q1" ] && [ "$(cat "$snap6$M_A/p.md")" = "p1${NL}p2" ]'
check "安全のための規則の記述を消す修正は承認待ち" '[ "$(cat "$M_A/r.md")" = "r1 permissions.deny で止める${NL}r2" ]'
check "2回訂正された種類の修正は承認待ち" '[ "$(cat "$M_A/s.md")" = "s1" ]'
new_props="$(ls -t "$PDIR"/*.md | grep -v -e rejections -e corrections | head -n $(( $(ls "$PDIR" | grep -vc -e rejections -e corrections) - n_before )))"
check "承認待ちは2件（r.md と s.md）" '[ "$(printf "%s\n" "$new_props" | grep -c .)" = "2" ]'
check "承認待ちの理由に判定の根拠を書く" 'grep -lq "安全のための規則" $new_props && grep -Fq "memory-audit/修正/proj-a/s.md）が訂正リストで 2 回訂正されている" $(grep -l "^  - $M_A/s.md\$" $new_props)'
auto="$(awk '/^### 承認なしで反映した変更/{f=1;next} /^#/{f=0} f' "$rep6")"
check "レポートに修正と削除を ID 付きで載せる" 'printf "%s" "$auto" | grep -Fq "\`$M_A/p.md\`（修正。種類 \`memory-audit/修正/proj-a/p.md\`。直す前の版 \`$snap6$M_A/p.md\`）" && printf "%s" "$auto" | grep -Fq "\`$M_A/q.md\`（削除。種類 \`memory-audit/削除/proj-a/q.md\`。直す前の版 \`$snap6$M_A/q.md\`）" && printf "%s" "$auto" | grep -Fq "索引 \`$M_A/MEMORY.md\` の、このメモリを指す行も消した"'
check "ID は日時と連番" '[ "$(printf "%s\n" "$auto" | grep -c "^- memory-audit-${snap6##*/}-0[12]: ")" = "2" ]'
check "レポートの件数" 'grep -Fq "承認なしで反映した変更 2件 / 承認待ちにした 2件" "$rep6"'

echo "== 変更の台帳に記録し、ID を渡して戻せる"
qid="$(printf '%s\n' "$auto" | sed -n "s|^- \(memory-audit-[^:]*\): \`$M_A/q.md\`.*|\1|p")"
pid="$(printf '%s\n' "$auto" | sed -n "s|^- \(memory-audit-[^:]*\): \`$M_A/p.md\`.*|\1|p")"
check "台帳は git のリポジトリで、ID ごとにコミットがある" '[ -d "$CLAUDE_CHANGE_LEDGER/.git" ] && git -C "$CLAUDE_CHANGE_LEDGER" log --format=%s | grep -q "^record: $qid memory-audit/削除/proj-a/q.md " && git -C "$CLAUDE_CHANGE_LEDGER" log --format=%s | grep -q "^record: $pid memory-audit/修正/proj-a/p.md "'
check "台帳に直す前と直した後の版を写す" '[ "$(cat "$CLAUDE_CHANGE_LEDGER/entries/$pid/1/before")" = "p1${NL}p2" ] && [ "$(cat "$CLAUDE_CHANGE_LEDGER/entries/$pid/1/after")" = "p1 直した${NL}p2" ] && [ ! -e "$CLAUDE_CHANGE_LEDGER/entries/$qid/1/after" ]'
check "削除と索引の行の削除は同じ ID で記録する" '[ "$(cat "$CLAUDE_CHANGE_LEDGER/entries/$qid/2/target")" = "$M_A/MEMORY.md" ]'
check "レポートに戻し方（revert.sh）を書く" 'grep -Fq "scripts/revert.sh に ID を渡す（変更の台帳 $CLAUDE_CHANGE_LEDGER から" "$rep6"'
out="$(bash "$CR_REAL/revert.sh" "$qid" 2>&1)"; rc=$?
check "削除を戻す: ファイルと索引の行が戻る" '[ "$rc" -eq 0 ] && [ "$(cat "$M_A/q.md")" = "q1" ] && [ "$(cat "$M_A/MEMORY.md")" = "- [A](a.md) — a${NL}- [Q](q.md) — q" ]'
check "戻した後に訂正リストへの追記を促す" 'printf "%s" "$out" | grep -Fq "corrections.sh add --id $qid --kind memory-audit/削除/proj-a/q.md"'
check "戻したことを台帳にコミットする" '[ "$(git -C "$CLAUDE_CHANGE_LEDGER" log -1 --format=%s)" = "revert: $qid" ]'
bash "$CR_REAL/revert.sh" "$qid" >/dev/null 2>&1; rc=$?
check "同じ ID を2回は戻さない" '[ "$rc" -ne 0 ]'
printf 'p1 さらに直した\np2\n' >"$M_A/p.md"
bash "$CR_REAL/revert.sh" "$pid" >/dev/null 2>&1; rc=$?
check "反映の後に変わっていれば戻さない" '[ "$rc" -eq 1 ] && [ "$(cat "$M_A/p.md")" = "p1 さらに直した${NL}p2" ]'
bash "$CR_REAL/revert.sh" "$pid" --force >/dev/null 2>&1; rc=$?
check "--force なら戻す" '[ "$rc" -eq 0 ] && [ "$(cat "$M_A/p.md")" = "p1${NL}p2" ] && [ "$(cat "$CLAUDE_CHANGE_LEDGER/entries/$pid/1/removed")" = "p1 さらに直した${NL}p2" ]'

echo "== 承認あり（screen）では修正と削除をすべて承認待ちにする"
printf 'u1\n' >"$M_A/u.md"
n_before="$(ls "$PDIR" | grep -vc -e rejections -e corrections)"
sleep 1
CLAUDE_REVIEW_APPROVAL_MODE=screen FAKE_HOOK='mkdir -p "$STAGE$S_A" && printf "u2\n" >"$STAGE$S_A/u.md" && printf "a1\na2\na3\n" >"$STAGE$S_A/a.md"' "$SCRIPT_DIR/run.sh"
check "修正は書き戻さない" '[ "$(cat "$M_A/u.md")" = "u1" ]'
check "追加だけの変更は書き戻す" '[ "$(cat "$M_A/a.md")" = "a1${NL}a2${NL}a3" ]'
new_props="$(ls -t "$PDIR"/*.md | grep -v -e rejections -e corrections | head -n $(( $(ls "$PDIR" | grep -vc -e rejections -e corrections) - n_before )))"
check "承認待ちの理由に承認ありの設定を書く" '[ "$(printf "%s\n" "$new_props" | grep -c .)" = "1" ] && grep -Fq "承認ありの設定（CLAUDE_REVIEW_APPROVAL_MODE=screen）" $new_props'
printf 'CLAUDE_REVIEW_APPROVAL_MODE=auto\n' >"$CLAUDE_REVIEW_JOBS_CONF"
check "jobs.conf の承認の進め方を読む" '[ "$(env -u CLAUDE_REVIEW_APPROVAL_MODE bash -c ". \"$CR_REAL/link-scopes.sh\"; approval_mode")" = "auto" ]'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
check "既定は承認あり（screen）" '[ "$(env -u CLAUDE_REVIEW_APPROVAL_MODE bash -c ". \"$CR_REAL/link-scopes.sh\"; approval_mode")" = "screen" ]'

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
