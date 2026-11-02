#!/bin/bash
# report-inbox scripts の検査。一時ディレクトリに偽のレポートを作って実行する。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/report-inbox-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# 本物の HOME の下の change-review・台帳を参照しないよう、HOME を一時ディレクトリにする。
export HOME="$WORK/home"
mkdir -p "$HOME"
export CLAUDE_REPORTS_ROOT="$WORK/reports"
export CLAUDE_REPORTS_STATE="$WORK/state"
export SKILL_AUDIT_STATE="$WORK/skill-audit-state"
unset CLAUDE_REVIEW_PROPOSALS
# 件数を数える change-review の scripts は、リポジトリの core のものを使う。
export CHANGE_REVIEW_SCRIPTS="$(cd "$SCRIPT_DIR/../../change-review/scripts" && pwd -P)"
R="$CLAUDE_REPORTS_ROOT"
READ="$CLAUDE_REPORTS_STATE/report-inbox/read.txt"
NL=$'\n'
# 速さの検査のしきい値（秒）。SessionStart のフックが会話の開始を待たせないことを確かめる。
# 0.5 秒では Mac の混み具合で前後に揺れて落ちたため、2倍の余裕を持たせる。件数の比で確かめる形は、
# 起動にかかる時間が大半を占めて比が揺れるため採らない。
LIMIT="${REPORT_INBOX_TEST_TIME_LIMIT:-1.0}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

echo "== レポートの置き場所が無い"
out="$("$SCRIPT_DIR/unread.sh" 2>&1)"
rc=$?
check "unread.sh は何も出さず終了コード0" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
out="$("$SCRIPT_DIR/list.sh" 2>&1)"
check "list.sh は何も出さない" '[ -z "$out" ]'

mkdir -p "$R/repo-patrol" "$R/feedback-mining" "$R/memory-audit/.snapshots/2026-10-05-103000/x" "$R/memory-audit/.staging/2026-10-05-103000/x" "$R/.hidden"
for f in repo-patrol/2026-10-05.md repo-patrol/2026-10-07.md repo-patrol/2026-10-07-2.md \
  feedback-mining/2026-10-05.md memory-audit/2026-10-05.md; do
  echo "# test" >"$R/$f"
done
echo x >"$R/memory-audit/.snapshots/2026-10-05-103000/x/2026-10-05.md"
echo x >"$R/memory-audit/.snapshots/2026-10-06.md"
echo x >"$R/memory-audit/.staging/2026-10-05-103000/x/2026-10-05.md"
echo x >"$R/memory-audit/.staging/2026-10-06.md"
echo x >"$R/.hidden/2026-10-05.md"
echo x >"$R/repo-patrol/notes.md"
echo x >"$R/repo-patrol/2026-10-08-x.md"
echo x >"$R/top-level.md"

echo "== unread.sh"
out="$("$SCRIPT_DIR/unread.sh")"
echo "$out"
check "1行だけ出す" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = "1" ]'
check "仕様の形で出す" '[ "$out" = "未読の結果: feedback-mining 1件（2026-10-05）、memory-audit 1件（2026-10-05）、repo-patrol 3件（最新 2026-10-07）" ]'

echo "== mark-read.sh"
out="$(cd "$R/feedback-mining" && "$SCRIPT_DIR/mark-read.sh" 2026-10-05.md)"
check "相対パスで既読にできる" 'grep -Fxq "$R/feedback-mining/2026-10-05.md" "$READ"'
"$SCRIPT_DIR/mark-read.sh" "$R/feedback-mining/2026-10-05.md" >/dev/null
check "重複して記録しない" '[ "$(grep -c . "$READ")" = "1" ]'
"$SCRIPT_DIR/mark-read.sh" "$R/repo-patrol/2026-10-07-2.md" >/dev/null
out="$("$SCRIPT_DIR/unread.sh")"
echo "$out"
check "既読を数えない" '[ "$out" = "未読の結果: memory-audit 1件（2026-10-05）、repo-patrol 2件（最新 2026-10-07）" ]'
for bad in "$R/repo-patrol/notes.md" "$R/memory-audit/.snapshots/2026-10-06.md" "$R/memory-audit/.staging/2026-10-06.md" "$R/.hidden/2026-10-05.md" "$R/top-level.md" \
  "$R/nosuch/2026-10-05.md" "/etc/hosts" "$R/repo-patrol/2026-10-08-x.md"; do
  "$SCRIPT_DIR/mark-read.sh" "$bad" >/dev/null 2>&1
  rc=$?
  check "拒否する: ${bad#$WORK/}（rc=${rc}）" '[ "$rc" -eq 1 ]'
done
check "拒否したものは記録しない" '[ "$(grep -c . "$READ")" = "2" ]'
"$SCRIPT_DIR/mark-read.sh" >/dev/null 2>&1
rc=$?
check "引数なしは終了コード2" '[ "$rc" -eq 2 ]'

echo "== list.sh"
out="$("$SCRIPT_DIR/list.sh")"
echo "$out"
check "5件出す" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = "5" ]'
check "先頭は最新（2026-10-07-2）" '[ "$(printf "%s\n" "$out" | head -1)" = "repo-patrol / 2026-10-07 / $R/repo-patrol/2026-10-07-2.md / 既読" ]'
check "2行目は 2026-10-07" '[ "$(printf "%s\n" "$out" | sed -n 2p)" = "repo-patrol / 2026-10-07 / $R/repo-patrol/2026-10-07.md / 未読" ]'
check "末尾は 2026-10-05" 'printf "%s\n" "$out" | tail -1 | grep -Fq " / 2026-10-05 / "'
check ".snapshots・.staging・ドット始まりと形の違うファイルを出さない" '! printf "%s" "$out" | grep -Eq "snapshots|staging|hidden|notes|top-level|10-08-x"'
out="$("$SCRIPT_DIR/list.sh" --unread)"
check "--unread は未読の3件だけ" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = "3" ] && ! printf "%s" "$out" | grep -q "既読"'

echo "== mark-read.sh --all"
"$SCRIPT_DIR/mark-read.sh" --all >/dev/null
out="$("$SCRIPT_DIR/unread.sh")"
check "--all の後は何も出さない" '[ -z "$out" ]'
check "記録は5件" '[ "$(grep -c . "$READ")" = "5" ]'

echo "== 失敗しても終了コード0で何も出さない"
chmod 000 "$CLAUDE_REPORTS_STATE/report-inbox"
echo "# test" >"$R/repo-patrol/2026-10-09.md"
out="$("$SCRIPT_DIR/unread.sh" 2>&1)"
rc=$?
chmod 755 "$CLAUDE_REPORTS_STATE/report-inbox"
check "既読の記録を読めない場合（rc=${rc}、出力: ${out}）" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
out="$(CLAUDE_REPORTS_ROOT="$WORK/nosuch" "$SCRIPT_DIR/unread.sh" 2>&1)"
rc=$?
check "置き場所が無い場合" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
cp -p "$SCRIPT_DIR/unread.sh" "$WORK/unread-alone.sh"
out="$("$WORK/unread-alone.sh" 2>&1)"
rc=$?
check "lib.sh が無い場合" '[ "$rc" -eq 0 ] && [ -z "$out" ]'

echo "== 速度（200件で${LIMIT}秒以内）"
for j in 1 2 3 4; do
  mkdir -p "$R/job$j"
  for d in $(seq -w 1 28); do
    for k in "" -2; do echo x >"$R/job$j/2026-09-$d$k.md"; done
  done
done
start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
"$SCRIPT_DIR/unread.sh" >/dev/null
end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
elapsed="$(perl -e "printf '%.3f', $end - $start")"
check "unread.sh は${LIMIT}秒以内（実際: ${elapsed}秒）" 'perl -e "exit(!($elapsed < $LIMIT))"'

echo "== 失敗の知らせ"
S="$CLAUDE_REPORTS_STATE"
SA="$SKILL_AUDIT_STATE"
# 前の検査の mark-read.sh --all が付けた失敗の既読の印を消し、印の無い状態から始める。
rm -rf "$S/report-inbox/failure-read"
mkdir -p "$S/repo-patrol/logs" "$S/memory-audit/logs" "$S/feedback-mining/logs" "$SA/logs"
# 現在の未読のレポートを片付け、失敗の知らせだけを見る。
"$SCRIPT_DIR/mark-read.sh" "$R"/*/*.md >/dev/null 2>&1
out="$("$SCRIPT_DIR/unread.sh")"
check "失敗なし: 何も出さない（出力: ${out}）" '[ -z "$out" ]'

printf '[2026-09-25 10:30:00] INFO: 精査を起動します\n' >"$S/memory-audit/logs/2026-09-25-103000.log"
printf '[2026-09-24 10:30:00] ERROR: 古い実行の失敗\n' >"$S/memory-audit/logs/2026-09-24-103000.log"
out="$("$SCRIPT_DIR/unread.sh")"
check "最新のログに ERROR が無ければ失敗としない（出力: ${out}）" '[ -z "$out" ]'

printf '[2026-09-26 10:30:00] INFO: 精査を起動します\n[2026-09-26 10:31:05] ERROR: 精査が異常終了しました（終了コード 1）\n' >"$S/memory-audit/logs/2026-09-26-103000.log"
out="$("$SCRIPT_DIR/unread.sh")"
echo "$out"
check "失敗あり: 失敗だけを出す" '[ "$out" = "失敗: memory-audit（2026-09-26 10:31。ログ $S/memory-audit/logs/2026-09-26-103000.log）" ]'

printf '[2026-09-26 09:00:00] ERROR: 別の実行が進行中です（%s が存在します）\n' "$S/repo-patrol/lock" >"$S/repo-patrol/launchd.stderr.log"
printf '[2026-09-26 09:00:00] ERROR: 別の実行が進行中です（%s が存在します）\n' "$S/repo-patrol/lock" >"$S/repo-patrol/logs/2026-09-26-090000.log"
out="$("$SCRIPT_DIR/unread.sh")"
check "除外する ERROR（二重起動の拒否）は失敗としない（出力: ${out}）" '! printf "%s" "$out" | grep -q repo-patrol'

printf 'bash: claude: command not found\n' >"$SA/launchd.stderr.log"
touch -t 202609271200 "$SA/launchd.stderr.log"
out="$("$SCRIPT_DIR/unread.sh")"
echo "$out"
check "標準エラーのみ: 更新時刻を添えて出す" 'printf "%s" "$out" | grep -Fq "skill-audit（2026-09-27 12:00。標準エラー $SA/launchd.stderr.log）"'

echo "# test" >"$R/repo-patrol/2026-10-10.md"
out="$("$SCRIPT_DIR/unread.sh")"
echo "$out"
check "結果と失敗の両方を1行に出す" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = "1" ] && [ "$out" = "未読の結果: repo-patrol 1件（2026-10-10）。失敗: memory-audit（2026-09-26 10:31。ログ $S/memory-audit/logs/2026-09-26-103000.log）、skill-audit（2026-09-27 12:00。標準エラー $SA/launchd.stderr.log）" ]'

out="$("$SCRIPT_DIR/list.sh" --failures)"
echo "$out"
check "list.sh --failures はジョブ・日時・パスと ERROR の行を出す" 'printf "%s\n" "$out" | grep -Fxq "memory-audit / 2026-09-26 10:31 / $S/memory-audit/logs/2026-09-26-103000.log" && printf "%s\n" "$out" | grep -Fxq "    [2026-09-26 10:31:05] ERROR: 精査が異常終了しました（終了コード 1）" && printf "%s\n" "$out" | grep -Fxq "    bash: claude: command not found"'
for i in 1 2 3 4 5; do printf '[2026-09-26 11:00:0%s] ERROR: 取得失敗: repo%s\n' "$i" "$i"; done >"$S/feedback-mining/logs/2026-09-26-110000.log"
out="$("$SCRIPT_DIR/list.sh" --failures)"
check "list.sh --failures の ERROR の行は先頭3行まで" '[ "$(printf "%s\n" "$out" | grep -c "取得失敗")" = "3" ] && printf "%s" "$out" | grep -q "repo3" && ! printf "%s" "$out" | grep -q "repo4"'

"$SCRIPT_DIR/mark-read.sh" --failure memory-audit >/dev/null
out="$("$SCRIPT_DIR/unread.sh")"
check "--failure で指定したジョブだけを既読にする（出力: ${out}）" '! printf "%s" "$out" | grep -q memory-audit && printf "%s" "$out" | grep -q skill-audit && printf "%s" "$out" | grep -q feedback-mining'
"$SCRIPT_DIR/mark-read.sh" --failure nosuch >/dev/null 2>&1
rc=$?
check "--failure に対象外のジョブ名は終了コード2" '[ "$rc" -eq 2 ]'

"$SCRIPT_DIR/mark-read.sh" --failures >/dev/null
out="$("$SCRIPT_DIR/unread.sh")"
check "既読の後は出ない（出力: ${out}）" '[ "$out" = "未読の結果: repo-patrol 1件（2026-10-10）" ]'
out="$("$SCRIPT_DIR/list.sh" --failures)"
check "既読の後は list.sh --failures も出さない" '[ -z "$out" ]'

# 既読にした後で、同じログと標準エラーに新しい失敗が足された場合。
sleep 1
now_ts="$(date '+%Y-%m-%d %H:%M:%S')"
printf '[%s] ERROR: 精査が異常終了しました（終了コード 2）\n' "$now_ts" >>"$S/memory-audit/logs/2026-09-26-103000.log"
printf 'bash: claude: command not found\n' >>"$SA/launchd.stderr.log"
printf '[%s] ERROR: 別の実行が進行中です（lock が存在します）\n' "$now_ts" >>"$S/repo-patrol/launchd.stderr.log"
out="$("$SCRIPT_DIR/unread.sh")"
echo "$out"
check "既読にした後の再発: 新しい ERROR と標準エラーだけを出す" 'printf "%s" "$out" | grep -Fq "memory-audit（${now_ts:0:16}。ログ" && printf "%s" "$out" | grep -Fq "skill-audit（" && ! printf "%s" "$out" | grep -q "repo-patrol（" && ! printf "%s" "$out" | grep -q feedback-mining'
out="$("$SCRIPT_DIR/list.sh" --failures)"
check "再発の list.sh は新しい行だけを出す" '[ "$(printf "%s\n" "$out" | grep -c "終了コード 1")" = "0" ] && [ "$(printf "%s\n" "$out" | grep -c "command not found")" = "1" ]'

"$SCRIPT_DIR/mark-read.sh" --all >/dev/null
out="$("$SCRIPT_DIR/unread.sh")"
check "--all は結果と失敗の両方を既読にする（出力: ${out}）" '[ -z "$out" ]'

printf 'x\n' >"$SA/launchd.stderr.log"
sleep 1; touch "$SA/launchd.stderr.log"
out="$("$SCRIPT_DIR/unread.sh")"
check "標準エラーが切り詰められた後の失敗も出す（出力: ${out}）" 'printf "%s" "$out" | grep -q "skill-audit（"'
"$SCRIPT_DIR/mark-read.sh" --failures >/dev/null

out="$(CLAUDE_REPORTS_ROOT="$WORK/nosuch" "$SCRIPT_DIR/mark-read.sh" --all 2>&1)"
rc=$?
check "置き場所が無くても --all は失敗の知らせを既読にする（rc=${rc}）" '[ "$rc" -eq 0 ]'

echo "== 速度（失敗あり。大きなログと標準エラーで${LIMIT}秒以内）"
for j in repo-patrol memory-audit feedback-mining; do
  for d in $(seq -w 1 30); do printf '[2026-10-01 00:00:00] INFO: x\n' >"$S/$j/logs/2026-11-$d-000000.log"; done
  { for i in $(seq 1 2000); do printf '[2026-09-30 00:00:00] INFO: 対象 %s\n' "$i"; done; printf '[2026-09-30 00:00:01] ERROR: 失敗\n'; } >"$S/$j/logs/2026-12-01-000000.log"
  for i in $(seq 1 2000); do printf 'warning %s\n' "$i"; done >"$S/$j/launchd.stderr.log"
done
# 既存の速度の検査と条件を揃えるため、既読の記録を外し、200件を超えるレポートを未読のまま数えさせる。
mv "$READ" "$READ.bak"
start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
out="$("$SCRIPT_DIR/unread.sh")"
end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
elapsed="$(perl -e "printf '%.3f', $end - $start")"
mv "$READ.bak" "$READ"
check "失敗ありの unread.sh は${LIMIT}秒以内（実際: ${elapsed}秒）" 'perl -e "exit(!($elapsed < $LIMIT))" && printf "%s" "$out" | grep -q "。失敗: "'

echo "== 直したいこと（Skill change-review）"
"$SCRIPT_DIR/mark-read.sh" --all >/dev/null
export CLAUDE_REVIEW_CHANGES_LOG="$WORK/changes/log.md"
CR="$SCRIPT_DIR/../../change-review/scripts"
: >"$WORK/empty.diff"
out="$("$SCRIPT_DIR/unread.sh")"
check "記録が無ければ何も出さない" '[ -z "$out" ]'
id="$(bash "$CR/new-change.sh" --source 会話 --title 直す --diff-file "$WORK/empty.diff" --target /path/to/a.md)"
expected="直したいこと 1件（うち要確認 1件、${id}〜）"
out="$("$SCRIPT_DIR/unread.sh")"
check "未対応の件数・要確認の件数・最も古いIDを1行で出す" '[ "$out" = "$expected" ]'
"$SCRIPT_DIR/mark-read.sh" --all >/dev/null
check "結果を既読にしても直したいことは残る" '[ "$("$SCRIPT_DIR/unread.sh")" = "$expected" ]'
out="$("$SCRIPT_DIR/list.sh" --changes)"
check "未対応の一覧を出す" 'printf "%s" "$out" | grep -Fq "$id / 直す /"'
"$SCRIPT_DIR/list.sh" --changes --unread >/dev/null 2>&1
check "一覧の種類を併用できない" '[ $? -eq 2 ]'
echo '# test' >"$R/repo-patrol/2026-10-11.md"
sleep 1
now_ts="$(date '+%Y-%m-%d %H:%M:%S')"
printf '[%s] ERROR: 精査が異常終了しました（終了コード 3）\n' "$now_ts" >"$S/memory-audit/logs/2099-01-01-000000.log"
out="$("$SCRIPT_DIR/unread.sh")"
check "記録・結果・失敗を1行に並べる" '[ "$out" = "${expected}。未読の結果: repo-patrol 1件（2026-10-11）。失敗: memory-audit（${now_ts:0:16}。ログ $S/memory-audit/logs/2099-01-01-000000.log）" ]'
rm -f "$S/memory-audit/logs/2099-01-01-000000.log"
"$SCRIPT_DIR/mark-read.sh" --all >/dev/null
bash "$CR/changes.sh" mark "$id" done 直した
check "対応済みなら知らせない" '[ -z "$("$SCRIPT_DIR/unread.sh")" ]'
id="$(bash "$CR/new-change.sh" --id-prefix memory-audit --kind 直してよい --source memory-audit --title 追加 --diff-file "$WORK/empty.diff" --target /path/to/b.md)"
check "直してよい項目だけなら要確認0件" '[ "$("$SCRIPT_DIR/unread.sh")" = "直したいこと 1件（うち要確認 0件、${id}〜）" ]'
mv "$R" "$R.save"
check "結果のディレクトリが無くても件数が出る" '[ "$("$SCRIPT_DIR/unread.sh")" = "直したいこと 1件（うち要確認 0件、${id}〜）" ]'
mv "$R.save" "$R"
bash "$CR/changes.sh" mark "$id" skip 見送る
check "見送りなら知らせない" '[ -z "$("$SCRIPT_DIR/unread.sh")" ]'

echo "== 速度（既読2000件、レポート2000件で${LIMIT}秒以内）"
rm -rf "$R"/job*
mkdir -p "$R/bulk"
: >"$READ.big"
for m in 01 02 03 04 05 06 07 08 09 10 11 12; do
  for d in $(seq -w 1 28); do
    for k in "" -2 -3 -4 -5 -6; do
      echo x >"$R/bulk/2025-$m-$d$k.md"
      printf '%s\n' "$R/bulk/2025-$m-$d$k.md" >>"$READ.big"
    done
  done
done
n_reports="$(ls "$R/bulk" | wc -l | tr -d ' ')"
# 既読のうち1件だけ記録から外し、未読として数えることも確かめる。
grep -v "2025-12-28-6.md" "$READ.big" >"$READ.tmp"
n_read="$(grep -c . "$READ.tmp")"
mv "$READ" "$READ.keep"
cat "$READ.keep" "$READ.tmp" >"$READ"
rm -f "$READ.big" "$READ.tmp"
start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
out="$("$SCRIPT_DIR/unread.sh")"
end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
elapsed="$(perl -e "printf '%.3f', $end - $start")"
check "レポート${n_reports}件・既読${n_read}件の unread.sh は${LIMIT}秒以内（実際: ${elapsed}秒、出力: ${out}）" '[ "$n_reports" -ge 2000 ] && [ "$n_read" -ge 2000 ] && perl -e "exit(!($elapsed < $LIMIT))" && [ "$out" = "未読の結果: bulk 1件（2025-12-28）" ]'
start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
out="$("$SCRIPT_DIR/list.sh" --unread)"
end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
elapsed="$(perl -e "printf '%.3f', $end - $start")"
check "同じ条件の list.sh --unread は${LIMIT}秒以内（実際: ${elapsed}秒）" 'perl -e "exit(!($elapsed < $LIMIT))" && printf "%s\n" "$out" | grep -c "/bulk/" | grep -qx 1 && [ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = "1" ]'
mv "$READ.keep" "$READ"

echo "== 実行権限"
for f in lib.sh unread.sh mark-read.sh list.sh test.sh; do
  check "実行権限: $f" '[ -x "$SCRIPT_DIR/$f" ]'
done

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
