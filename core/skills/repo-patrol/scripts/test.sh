#!/bin/bash
# repo-patrol scripts の検査。一時ディレクトリに偽のリポジトリ群を作って実行する。ネットワークは使わない。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-patrol-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export REPO_PATROL_ROOT="$WORK/git"
export CLAUDE_REPORTS_ROOT="$WORK/reports"
export CLAUDE_REPORTS_STATE="$WORK/state"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
G="$REPO_PATROL_ROOT"
STATE="$CLAUDE_REPORTS_STATE/repo-patrol"

cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = test_user_01
	email = test_user_01@example.com
[init]
	defaultBranch = main
EOF

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
commit() { echo "$2" >>"$1/file.txt"; q "$1" add file.txt; q "$1" commit -m "$2"; }

mkdir -p "$G" "$WORK/remote"
# origin となる bare リポジトリ。clone はローカルのパスで行う。
git init -q --bare "$WORK/remote/origin.git"
git init -q "$WORK/seed"
commit "$WORK/seed" "初期"
q "$WORK/seed" push "$WORK/remote/origin.git" main

# pristine: 何も無い
git clone -q "$WORK/remote/origin.git" "$G/pristine"
# clean: 作業ツリーは綺麗だが、下で作るワークツリーのブランチ（上流なし）を持つ
git clone -q "$WORK/remote/origin.git" "$G/clean"
# dirty: staged 1 / unstaged 1 / untracked 2、stash 1、ahead 1、上流なしのブランチ、マージ済みブランチ
git clone -q "$WORK/remote/origin.git" "$G/dirty"
q "$G/dirty" branch merged-topic
q "$G/dirty" branch local-only
commit "$G/dirty" "ahead"
echo s >"$G/dirty/stash.txt"; q "$G/dirty" add stash.txt; q "$G/dirty" stash
echo a >"$G/dirty/staged.txt"; q "$G/dirty" add staged.txt
echo b >>"$G/dirty/file.txt"
echo c >"$G/dirty/untracked1.txt"; echo d >"$G/dirty/untracked2.txt"
touch -t 202601020304 "$G/dirty/.git/FETCH_HEAD"
# cleanup: マージ済みブランチだけがある
git clone -q "$WORK/remote/origin.git" "$G/cleanup"
q "$G/cleanup" branch done-feature
# noremote: origin なし。master が既定ブランチになる
git init -q -b master "$G/noremote"
commit "$G/noremote" "初期"
q "$G/noremote" branch old-work
# worktree: .git がファイルのもの
q "$G/clean" worktree add -q "$G/wt" -b wt-branch
# broken: .git があるが壊れている
mkdir -p "$G/broken"; echo "gitdir: /nonexistent/path" >"$G/broken/.git"
# 対象外: .git の無いディレクトリと通常ファイル
mkdir -p "$G/plain"; echo x >"$G/plain/readme.txt"; echo x >"$G/file-not-dir"
# 1段下: .git の無いディレクトリの下のリポジトリは数える。2段下は数えない
mkdir -p "$G/group/deeper"
git clone -q "$WORK/remote/origin.git" "$G/group/nested"
git clone -q "$WORK/remote/origin.git" "$G/group/deeper/too-deep"
# リポジトリの中には入らない（broken の下のリポジトリは数えない）
git init -q "$G/broken/inner"

echo "== ネットワークに触れる git コマンドを使っていない"
check "fetch/pull/push/ls-remote/remote update を含まない" \
  '! grep -Eq "(^|[^a-z-])(fetch|pull|push|ls-remote|remote update|clone)( |$)" <(grep -v "^ *#" "$SCRIPT_DIR/patrol.sh" | grep -v FETCH_HEAD | grep -v "printf")'

echo "== 通常実行"
"$SCRIPT_DIR/patrol.sh"
rc=$?
day="$(date '+%Y-%m-%d')"
rep="$CLAUDE_REPORTS_ROOT/repo-patrol/$day.md"
check "終了コード0" '[ "$rc" -eq 0 ]'
check "レポートが作られる" '[ -f "$rep" ]'
cat "$rep"
has() { grep -Fq -- "$1" "$rep"; }
section() { awk -v h="## $1" '$0==h{f=1;next} /^## /{f=0} f' "$rep"; }
check "対象件数は8件（pristine clean dirty cleanup noremote wt broken group/nested）" 'has "（8件）"'
check "作成日時がある" 'has "作成日時: "'
act="$(section "対応が要るもの")"
check "dirty の件数（staged 1 / unstaged 1 / untracked 2 / stash 1）" \
  'printf "%s" "$act" | grep -Fq "| dirty | main | 1 | 1 | 2 | 1 | origin/main: ahead 1 / behind 0 |"'
check "dirty の未push に main（1件）と local-only（上流なし）" \
  'printf "%s" "$act" | grep "| dirty |" | grep -Fq "main（1件）" && printf "%s" "$act" | grep "| dirty |" | grep -Fq "local-only（上流なし）"'
check "dirty の最終取得は FETCH_HEAD の日時" 'printf "%s" "$act" | grep "| dirty |" | grep -Fq "2026-01-02 03:04"'
check "noremote は上流なしとして対応が要る" 'printf "%s" "$act" | grep "| noremote |" | grep -Fq "上流なし"'
check "wt（ワークツリー）は上流なしのブランチとして対応が要る" 'printf "%s" "$act" | grep -Fq "| wt | wt-branch |"'
check "clean はワークツリーのブランチが上流なしとして対応が要る" 'printf "%s" "$act" | grep "| clean |" | grep -Fq "wt-branch（上流なし）"'
check "pristine は対応が要るものに無い" '! printf "%s" "$act" | grep -Fq "| pristine |"'
cln="$(section "片付けの候補")"
check "cleanup の done-feature が候補" 'printf "%s" "$cln" | grep -Fq "| cleanup | origin/main | done-feature |"'
check "dirty の merged-topic と local-only が候補" 'printf "%s" "$cln" | grep "| dirty |" | grep -Fq "merged-topic"'
check "現在のブランチは候補に入れない" '! printf "%s" "$cln" | grep "| dirty |" | grep -Fq "main,"'
check "noremote は master を既定として old-work が候補" 'printf "%s" "$cln" | grep -Fq "| noremote | master | old-work |"'
check "clean は wt-branch を候補に出す（main にマージ済み）" 'printf "%s" "$cln" | grep -Fq "| clean | origin/main | wt-branch |"'
fl="$(section "取得失敗")"
check "broken は取得失敗として理由付き" 'printf "%s" "$fl" | grep -Fq "| broken | git rev-parse が失敗しました"'
okl="$(section "問題なし")"
check "問題なしは pristine と group/nested だけ" '[ "$(printf "%s\n" "$okl" | grep -c "^- ")" = "2" ] && printf "%s" "$okl" | grep -Fq -- "- pristine（main、最終取得 不明）" && printf "%s" "$okl" | grep -Fq -- "- group/nested（main、最終取得 不明）"'
check "plain は対象外" '! has "plain"'
check "2段下の too-deep は対象外" '! has "too-deep"'
check "リポジトリの中の inner は対象外" '! has "inner"'
check "正常時は0件の警告を書かない" '! has "警告: "'
check "正常時は読めなかったフォルダの節を書かない" '! has "## 読めなかったフォルダ"'
check "lock が解放されている" '[ ! -d "$STATE/lock" ]'
check "ログが作られる" '[ -n "$(ls "$STATE/logs/"*.log 2>/dev/null)" ]'

echo "== 同日2回目は連番"
"$SCRIPT_DIR/patrol.sh"
check "2回目は ${day}-2.md" '[ -f "$CLAUDE_REPORTS_ROOT/repo-patrol/$day-2.md" ]'
"$SCRIPT_DIR/patrol.sh"
check "3回目は ${day}-3.md" '[ -f "$CLAUDE_REPORTS_ROOT/repo-patrol/$day-3.md" ]'

echo "== 何も無い区分は該当なし"
rm -rf "$G"/*
git clone -q "$WORK/remote/origin.git" "$G/only"
out="$("$SCRIPT_DIR/patrol.sh" --stdout)"
check "--stdout は標準出力へ出す" 'printf "%s" "$out" | grep -Fq "# リポジトリ巡回レポート"'
check "対応が要るものは該当なし" 'printf "%s\n" "$out" | awk "/^## 対応が要るもの/{f=1;next} /^## /{f=0} f" | grep -Fxq "該当なし"'
check "問題なしに only（最終取得は不明）" 'printf "%s" "$out" | grep -Fq -- "- only（main、最終取得 不明）"'

echo "== 読み取りのみ（巡回で作業ツリーと参照が変わらない）"
before="$(cd "$G/only" && git status --porcelain; git -C "$G/only" for-each-ref; ls -la "$G/only/.git")"
"$SCRIPT_DIR/patrol.sh" --stdout >/dev/null
after="$(cd "$G/only" && git status --porcelain; git -C "$G/only" for-each-ref; ls -la "$G/only/.git")"
check "状態が変わらない" '[ "$before" = "$after" ]'

echo "== 二重起動の拒否"
mkdir "$STATE/lock"
"$SCRIPT_DIR/patrol.sh" --stdout >/dev/null 2>&1
rc=$?
check "lock があれば終了コード1" '[ "$rc" -eq 1 ]'
check "他者の lock を消さない" '[ -d "$STATE/lock" ]'
rmdir "$STATE/lock"

echo "== 対象ディレクトリが無い"
REPO_PATROL_ROOT="$WORK/nosuch" "$SCRIPT_DIR/patrol.sh" --stdout >/dev/null 2>&1
rc=$?
check "終了コード1" '[ "$rc" -eq 1 ]'

echo "== 対象のフォルダの一覧を読めない"
mkdir -p "$WORK/locked"
git clone -q "$WORK/remote/origin.git" "$WORK/locked/hidden"
chmod 000 "$WORK/locked"
rm -rf "$WORK/lockreports"
CLAUDE_REPORTS_ROOT="$WORK/lockreports" REPO_PATROL_ROOT="$WORK/locked" "$SCRIPT_DIR/patrol.sh"
rc=$?
chmod 755 "$WORK/locked"
lrep="$WORK/lockreports/repo-patrol/$day.md"
llog="$(ls -1t "$STATE/logs/"*.log | head -1)"
check "終了コード1" '[ "$rc" -eq 1 ]'
check "レポートは書く" '[ -f "$lrep" ]'
check "対象の行に読めなかった理由を書く" 'grep -Fq "（読めなかった: Permission denied）" "$lrep"'
check "読めなかったフォルダの節に載る" 'grep -Fq "| $WORK/locked | Permission denied |" "$lrep"'
check "0件の警告と取り違えない" '! grep -Fq "警告: " "$lrep"'
check "ログに ERROR の行がある" 'grep -Eq "^\[[0-9-]+ [0-9:]+\] ERROR: 読めなかった: " "$llog"'
out="$(chmod 000 "$WORK/locked"; REPO_PATROL_ROOT="$WORK/locked" "$SCRIPT_DIR/patrol.sh" --stdout 2>"$WORK/lock.err")"
rc=$?
chmod 755 "$WORK/locked"
check "--stdout でも終了コード1" '[ "$rc" -eq 1 ]'
check "--stdout でも ERROR を標準エラーへ出す" 'grep -Fq "ERROR: 読めなかった: " "$WORK/lock.err"'

echo "== 1段下のフォルダの一覧を読めない"
mkdir -p "$G/locked-group"
chmod 000 "$G/locked-group"
out="$("$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
rc=$?
chmod 755 "$G/locked-group"
rmdir "$G/locked-group"
check "終了コード1" '[ "$rc" -eq 1 ]'
check "読めたリポジトリは巡回する（1件）" 'printf "%s" "$out" | grep -Fq "（1件）"'
check "読めなかったフォルダの節に載る" 'printf "%s" "$out" | grep -Fq "| $G/locked-group | Permission denied |"'

echo "== 対象が0件"
mkdir -p "$WORK/empty/sub"
out="$(REPO_PATROL_ROOT="$WORK/empty" "$SCRIPT_DIR/patrol.sh" --stdout 2>"$WORK/empty.err")"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "WARN を標準エラーへ出す" 'grep -Fq "WARN: 巡回の対象のリポジトリが0件です" "$WORK/empty.err"'
check "ERROR は出さない" '! grep -Fq "ERROR" "$WORK/empty.err"'
check "レポートに0件の警告を書く" 'printf "%s" "$out" | grep -Fq "（0件）" && printf "%s" "$out" | grep -Fq "警告: 対象のリポジトリが0件である"'

echo "== run-if-due.sh（SessionStart の hook からの起動）"
RID="$SCRIPT_DIR/run-if-due.sh"
RR="$WORK/rid-reports"
RS="$WORK/rid-state"
RSD="$RS/repo-patrol"
# 起動の lock が外れる（裏の patrol.sh が終わる）まで待つ。最大20秒。
wait_trigger() {
  local i=0
  while [ -d "$RSD/trigger.lock" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
}
rid() {
  CLAUDE_REPORTS_ROOT="$RR" CLAUDE_REPORTS_STATE="$RS" "$RID" "$@"
}
yday="$(date -v-1d '+%Y-%m-%d')"
mkdir -p "$RR/repo-patrol"
echo "# 前日" >"$RR/repo-patrol/$yday.md"
t0="$(date +%s)"
out="$(rid)"
rc=$?
t1="$(date +%s)"
check "前日の結果しか無ければ動く: 終了コード0" '[ "$rc" -eq 0 ]'
check "標準出力が空" '[ -z "$out" ]'
check "すぐに戻る（2秒以内）" '[ $((t1 - t0)) -le 2 ]'
wait_trigger
check "今日の結果ができる" '[ -f "$RR/repo-patrol/$day.md" ]'
check "起動の lock が外れる" '[ ! -d "$RSD/trigger.lock" ]'
check "patrol.sh のログが作られる" '[ -n "$(ls "$RSD/logs/"*.log 2>/dev/null)" ]'
out="$(rid 2>&1)"
rc=$?
wait_trigger
check "今日の結果があれば動かない（連番の結果を作らない）" '[ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -f "$RR/repo-patrol/$day-2.md" ]'

rm -f "$RR/repo-patrol/$day.md"
mkdir "$RSD/trigger.lock"
out="$(rid 2>&1)"
rc=$?
sleep 1
check "起動の lock があれば動かない" '[ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -f "$RR/repo-patrol/$day.md" ]'
check "新しい起動の lock を消さない" '[ -d "$RSD/trigger.lock" ]'
touch -t 202001010000 "$RSD/trigger.lock"
out="$(rid 2>&1)"
wait_trigger
check "2時間より古い起動の lock は外して動く" '[ -z "$out" ] && [ -f "$RR/repo-patrol/$day.md" ]'

rm -f "$RR/repo-patrol/$day.md"
mkdir "$RSD/lock"
out="$(rid 2>&1)"
sleep 1
check "patrol.sh が実行中（lock あり）なら動かない" '[ -z "$out" ] && [ ! -f "$RR/repo-patrol/$day.md" ] && [ ! -d "$RSD/trigger.lock" ]'
rmdir "$RSD/lock"

out1="$(rid 2>&1)"
out2="$(rid 2>&1)"
wait_trigger
sleep 1
check "続けて2回呼んでも1回だけ動く" '[ -z "$out1$out2" ] && [ -f "$RR/repo-patrol/$day.md" ] && [ ! -f "$RR/repo-patrol/$day-2.md" ]'

echo "== run-if-due.sh: 対象のフォルダを読めない"
rm -rf "$RR" "$RS"
chmod 000 "$WORK/locked"
out="$(CLAUDE_REPORTS_ROOT="$RR" CLAUDE_REPORTS_STATE="$RS" REPO_PATROL_ROOT="$WORK/locked" "$RID" 2>&1)"
rc=$?
sleep 1
chmod 755 "$WORK/locked"
check "終了コード0" '[ "$rc" -eq 0 ]'
check "標準出力と標準エラーが空" '[ -z "$out" ]'
check "結果を書かない" '[ ! -e "$RR/repo-patrol" ]'
check "ログを書かない（report-inbox の失敗の知らせに出ない）" '[ ! -e "$RSD/logs" ]'
check "見送ったことを skipped.log に1行だけ残す" \
  '[ "$(wc -l <"$RSD/skipped.log" | tr -d " ")" = "1" ] && grep -Eq "^\[[0-9-]+ [0-9:]+\] SKIP: " "$RSD/skipped.log"'
check "起動の lock を残さない" '[ ! -d "$RSD/trigger.lock" ]'
out="$(CLAUDE_REPORTS_ROOT="$RR" CLAUDE_REPORTS_STATE="$RS" REPO_PATROL_ROOT="$WORK/nosuch" "$RID" 2>&1)"
rc=$?
check "対象のフォルダが無いときも何もせず終了コード0" '[ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$RR/repo-patrol" ] && [ ! -e "$RSD/logs" ]'

echo "== 巡回の対象の設定ファイル"
rm -rf "$RR" "$RS"
out="$(env -u REPO_PATROL_ROOT CLAUDE_REVIEW_PATROL_CONF="$WORK/nosuch.conf" CLAUDE_REPORTS_ROOT="$RR" CLAUDE_REPORTS_STATE="$RS" "$RID" 2>&1)"
rc=$?
sleep 1
check "設定ファイルも REPO_PATROL_ROOT も無ければ run-if-due.sh は何もしない" '[ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$RR/repo-patrol" ] && [ ! -e "$RSD" ]'
out="$(env -u REPO_PATROL_ROOT CLAUDE_REVIEW_PATROL_CONF="$WORK/nosuch.conf" CLAUDE_REPORTS_ROOT="$RR" CLAUDE_REPORTS_STATE="$RS" "$SCRIPT_DIR/patrol.sh" 2>&1)"
rc=$?
check "設定ファイルも REPO_PATROL_ROOT も無ければ patrol.sh は巡回せず終了コード0" '[ "$rc" -eq 0 ] && printf "%s" "$out" | grep -q "巡回しません" && [ ! -e "$RR/repo-patrol" ] && [ ! -e "$RSD" ]'
printf 'PERSONAL_FOLDERS=no\nREPO_ROOTS=\n' >"$WORK/patrol-empty.conf"
out="$(env -u REPO_PATROL_ROOT CLAUDE_REVIEW_PATROL_CONF="$WORK/patrol-empty.conf" CLAUDE_REPORTS_ROOT="$RR" CLAUDE_REPORTS_STATE="$RS" "$RID" 2>&1)"
sleep 1
check "REPO_ROOTS が空なら何もしない" '[ -z "$out" ] && [ ! -e "$RR/repo-patrol" ]'
printf 'PERSONAL_FOLDERS=no\nREPO_ROOTS=%s:%s\n' "$G" "$WORK/other" >"$WORK/patrol-git.conf"
out="$(env -u REPO_PATROL_ROOT CLAUDE_REVIEW_PATROL_CONF="$WORK/patrol-git.conf" CLAUDE_REPORTS_ROOT="$RR" CLAUDE_REPORTS_STATE="$RS" "$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "設定ファイルの REPO_ROOTS の先頭を巡回する" 'printf "%s" "$out" | grep -Fq -- "- 対象: ${G}（"'

echo "== ログの保持件数"
for i in $(seq 1 40); do touch -t "200001010000.$(printf '%02d' $((i % 60)))" "$STATE/logs/old-$i.log"; done
"$SCRIPT_DIR/patrol.sh"
n="$(ls "$STATE/logs/"*.log | wc -l | tr -d ' ')"
check "ログは30件以下（実際: ${n}）" '[ "$n" -le 30 ]'

echo "== launchd の plist を持たない（SessionStart の hook で動く）"
check "launchd のフォルダが無い" '[ ! -e "$SCRIPT_DIR/../launchd" ]'

echo "== 実行権限"
for f in patrol.sh test.sh run-if-due.sh; do
  check "実行権限: $f" '[ -x "$SCRIPT_DIR/$f" ]'
done

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
