#!/bin/bash
# install.sh の定期実行（週1回の棚卸しと local の3つ）の検査。一時の HOME を作り、launchctl を偽のコマンドに差し替えて実行する。
# 本物の HOME・launchctl・brew・terminal-notifier には触れない。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
# 公開版（local が無い版）では、local を前提にした検査を飛ばす。
HAS_LOCAL=0
[ -d "$REPO/local/skills" ] && HAS_LOCAL=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-install-schedule-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽の launchctl。呼ばれた引数を CALLS へ記録し、登録の状態をラベルごとのファイルで持つ。
# brew と terminal-notifier は置かない（install.sh は警告して続ける）。
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
export CALLS="$WORK/calls.log"
export FAKE_LAUNCHD="$WORK/launchd-registered"
cat >"$FAKEBIN/launchctl" <<'FAKE'
#!/bin/bash
printf 'launchctl %s\n' "$*" >>"$CALLS"
case "$1" in
  print) [ -f "$FAKE_LAUNCHD/${2##*/}" ] ;;
  bootstrap) mkdir -p "$FAKE_LAUNCHD" && touch "$FAKE_LAUNCHD/$(plutil -extract Label raw "$3")" ;;
  bootout) rm -f "$FAKE_LAUNCHD/${2##*/}" ;;
esac
FAKE
chmod +x "$FAKEBIN/launchctl"
ln -s "$(command -v jq)" "$FAKEBIN/jq"
export PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin"

export HOME="$WORK/home"
unset CLAUDE_REVIEW_LABEL CLAUDE_REVIEW_PORT CLAUDE_REVIEW_PYTHON CLAUDE_REVIEW_LOOP_WEEKDAY CLAUDE_REVIEW_LOOP_HOUR \
  CLAUDE_REVIEW_LOOP_MINUTE CLAUDE_REVIEW_LOOP_MODEL CLAUDE_REVIEW_LOOP_EFFORT
mkdir -p "$HOME/.claude" "$HOME/.claude2/skills"
ln -s ../.claude2/skills "$HOME/.claude/skills"
printf '{}\n' >"$HOME/.claude/settings.json"
S2="$HOME/.claude2/skills"
AG="$HOME/Library/LaunchAgents"
U="com.$(id -un | tr . -)"
LOOP_LABEL="$U.review-loop"
LOOP_PLIST="$AG/$LOOP_LABEL.plist"
JOBS="$HOME/.local/state/claude-review-inbox/scheduled-jobs.tsv"
UIDN="$(id -u)"

# 標準入力を疑似端末にして install.sh を動かす。$1 は入力する文字列。
tty_install() {
  local input="$1"
  shift
  /usr/bin/python3 - "$input" "$REPO/install.sh" "$@" <<'PY'
import os, subprocess, sys
m, s = os.openpty()
os.write(m, sys.argv[1].encode())
p = subprocess.run(sys.argv[2:], stdin=s, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
sys.stdout.write(p.stdout.decode())
sys.exit(p.returncode)
PY
}
tree_sig() {
  (cd "$HOME" && find . \( -type f -o -type l -o -type d \) -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"
    elif [ -f "$f" ]; then printf 'F %s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
    else printf 'D %s\n' "$f"; fi
  done)
}
px() { plutil -extract "$2" raw "$1" 2>/dev/null; }

echo "== 本体だけ・非端末で指定なし"
out="$("$REPO/install.sh" </dev/null 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "聞かない" '! printf "%s" "$out" | grep -q "\[y/N\]"'
check "棚卸しを登録しない" '[ ! -e "$LOOP_PLIST" ] && ! grep -q "review-loop" "$CALLS"'
check "棚卸しのスキルはリンクで置く" '[ "$(readlink "$S2/review-loop")" = "$REPO/core/skills/review-loop" ]'

echo "== 本体だけ・聞かれて n"
: >"$CALLS"
out="$(tty_install $'n\n')"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "聞く（利用枠を使うことも示す）" 'printf "%s" "$out" | grep -q "週1回の棚卸しを入れますか \[y/N\]" && printf "%s" "$out" | grep -q "利用枠を使います"'
check "登録しない" '[ ! -e "$LOOP_PLIST" ] && ! grep -q "review-loop" "$CALLS"'

echo "== 本体だけ・聞かれて y"
: >"$CALLS"
out="$(tty_install $'y\n')"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "plist を作る" '[ -f "$LOOP_PLIST" ] && plutil -lint "$LOOP_PLIST" >/dev/null'
check "ラベルと起動スクリプト" '[ "$(px "$LOOP_PLIST" Label)" = "$LOOP_LABEL" ] && [ "$(px "$LOOP_PLIST" ProgramArguments.1)" = "$S2/review-loop/scripts/run.sh" ]'
check "既定は毎週月曜 10:00" '[ "$(px "$LOOP_PLIST" StartCalendarInterval.Weekday)" = "1" ] && [ "$(px "$LOOP_PLIST" StartCalendarInterval.Hour)" = "10" ] && [ "$(px "$LOOP_PLIST" StartCalendarInterval.Minute)" = "0" ]'
check "モデルの指定が無ければ書かない" '[ -z "$(px "$LOOP_PLIST" EnvironmentVariables.CLAUDE_REVIEW_LOOP_MODEL)" ]'
check "launchctl bootstrap で登録する" 'grep -Fxq "launchctl bootstrap gui/$UIDN $LOOP_PLIST" "$CALLS"'
check "台帳に記録する" 'grep -q "^review-loop	$LOOP_LABEL	$LOOP_PLIST	0$" "$JOBS"'

echo "== --no-schedule は登録済みの棚卸しを外す"
: >"$CALLS"
out="$("$REPO/install.sh" --no-schedule </dev/null 2>&1)"
check "plist を消し、bootout する" '[ ! -e "$LOOP_PLIST" ] && grep -Fxq "launchctl bootout gui/$UIDN/$LOOP_LABEL" "$CALLS"'
check "台帳から消す" '[ ! -f "$JOBS" ] || ! grep -q "^review-loop" "$JOBS"'

echo "== --with-schedule と時刻・モデルの指定"
: >"$CALLS"
out="$(CLAUDE_REVIEW_LOOP_WEEKDAY=3 CLAUDE_REVIEW_LOOP_HOUR=07 CLAUDE_REVIEW_LOOP_MINUTE=05 CLAUDE_REVIEW_LOOP_MODEL=sonnet \
  "$REPO/install.sh" --with-schedule </dev/null 2>&1)"
rc=$?
check "終了コード0で聞かない" '[ "$rc" -eq 0 ] && ! printf "%s" "$out" | grep -q "\[y/N\]"'
check "時刻を plist に書く" '[ "$(px "$LOOP_PLIST" StartCalendarInterval.Weekday)" = "3" ] && [ "$(px "$LOOP_PLIST" StartCalendarInterval.Hour)" = "7" ] && [ "$(px "$LOOP_PLIST" StartCalendarInterval.Minute)" = "5" ]'
check "モデルを plist の環境変数に書く" '[ "$(px "$LOOP_PLIST" EnvironmentVariables.CLAUDE_REVIEW_LOOP_MODEL)" = "sonnet" ] && [ -z "$(px "$LOOP_PLIST" EnvironmentVariables.CLAUDE_REVIEW_LOOP_EFFORT)" ]'
"$REPO/install.sh" --with-schedule </dev/null >/dev/null 2>&1
sig="$(tree_sig)"
: >"$CALLS"
"$REPO/install.sh" --with-schedule </dev/null >/dev/null 2>&1
check "2回実行しても HOME が同じ" '[ "$(tree_sig)" = "$sig" ]'
check "登録済みなら bootout してから bootstrap する" '[ "$(grep "review-loop" "$CALLS" | grep "^launchctl boot" | cut -d" " -f2 | tr "\n" " ")" = "bootout bootstrap " ]'
out="$(CLAUDE_REVIEW_LOOP_HOUR=25 "$REPO/install.sh" --with-schedule </dev/null 2>&1)"
rc=$?
check "時刻が正しくなければ警告して登録を変えない（終了コード0）" '[ "$rc" -eq 0 ] && printf "%s" "$out" | grep -q "棚卸しの時刻の指定が正しくありません" && [ "$(px "$LOOP_PLIST" StartCalendarInterval.Hour)" = "10" ]'
"$REPO/install.sh" --with-schedule --no-schedule >/dev/null 2>&1
check "--with-schedule と --no-schedule の同時指定は終了コード2" '[ $? -eq 2 ]'

if [ "$HAS_LOCAL" -eq 1 ]; then
echo "== --with-local（既存のラベルの引き継ぎを含む）"
# 利用者の Mac と同じく、別のラベルで memory-audit を手で登録してある状態を作る。
mkdir -p "$AG"
OLD_PL="$AG/com.handmade.memory-audit.plist"
sed -e "s|@@LABEL@@|com.handmade.memory-audit|" -e "s|@@SCRIPT@@|$S2/memory-audit/scripts/run.sh|" -e "s|@@HOME@@|/old/home|g" \
  "$REPO/local/skills/memory-audit/launchd/memory-audit.plist.template" >"$OLD_PL"
old_sum="$(shasum -a 256 <"$OLD_PL")"
touch "$FAKE_LAUNCHD/com.handmade.memory-audit"
: >"$CALLS"
out="$(tty_install '' --with-local)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "棚卸しは聞かない" '! printf "%s" "$out" | grep -q "\[y/N\]"'
check "登録済みの棚卸しを外す" '[ ! -e "$LOOP_PLIST" ] && grep -Fxq "launchctl bootout gui/$UIDN/$LOOP_LABEL" "$CALLS"'
check "既存のラベルを引き継ぐ（二重に登録しない）" '[ ! -e "$AG/$U.memory-audit.plist" ] && [ "$(px "$OLD_PL" Label)" = "com.handmade.memory-audit" ] && printf "%s" "$out" | grep -q "既存のラベルを引き継ぎます: com.handmade.memory-audit"'
check "引き継いだ plist を書き換え、bootout してから bootstrap する" '[ "$(px "$OLD_PL" StandardOutPath)" = "$HOME/.local/state/claude-reports/memory-audit/launchd.stdout.log" ] && [ "$(grep "handmade" "$CALLS" | grep "^launchctl boot" | cut -d" " -f2 | tr "\n" " ")" = "bootout bootstrap " ]'
bk="$(ls "$HOME/.local/state/claude-review-inbox/plist-backup/"*/com.handmade.memory-audit.plist 2>/dev/null | head -1)"
check "書き換える前の plist を複製する" '[ -n "$bk" ] && [ "$(shasum -a 256 <"$bk")" = "$old_sum" ]'
check "他の2つは既定のラベルで登録する" '[ "$(px "$AG/$U.feedback-mining.plist" Label)" = "$U.feedback-mining" ] && [ "$(px "$AG/$U.skill-audit.plist" Label)" = "$U.skill-audit" ] && grep -Fxq "launchctl bootstrap gui/$UIDN $AG/$U.skill-audit.plist" "$CALLS"'
check "起動スクリプトはスキル置き場の中" '[ "$(px "$AG/$U.feedback-mining.plist" ProgramArguments.1)" = "$S2/feedback-mining/scripts/run.sh" ] && [ "$(px "$AG/$U.skill-audit.plist" ProgramArguments.1)" = "$S2/skill-audit/scripts/run-audit.sh" ]'
check "時刻はひな形のまま（memory-audit 10:30・feedback-mining 11:00・skill-audit 10:00）" '[ "$(px "$OLD_PL" StartCalendarInterval.Minute)" = "30" ] && [ "$(px "$AG/$U.feedback-mining.plist" StartCalendarInterval.Hour)" = "11" ] && [ "$(px "$AG/$U.skill-audit.plist" StartCalendarInterval.Hour)" = "10" ]'
check "ログの置き場所を作る" '[ -d "$HOME/.local/state/claude-reports/feedback-mining" ] && [ -d "$HOME/.local/state/skill-audit" ]'
check "台帳に3つを記録する（引き継ぎの印つき）" '[ "$(wc -l <"$JOBS" | tr -d " ")" = "3" ] && grep -q "^memory-audit	com.handmade.memory-audit	$OLD_PL	1$" "$JOBS"'
sig="$(tree_sig)"
: >"$CALLS"
"$REPO/install.sh" --with-local </dev/null >/dev/null 2>&1
check "2回実行しても HOME が同じ（複製も増えない）" '[ "$(tree_sig)" = "$sig" ]'
check "2回目も同じラベルで登録し直す" '[ "$(grep -c "^launchctl bootstrap" "$CALLS")" = "4" ] && grep -q "bootstrap gui/$UIDN $OLD_PL" "$CALLS"'

echo "== --uninstall"
: >"$CALLS"
out="$("$REPO/install.sh" --uninstall 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "引き継いだラベルを外す前に表示する" 'printf "%s" "$out" | grep -q "定期実行を外します（既存のラベルを引き継いだもの）: com.handmade.memory-audit"'
check "3つの定期実行を外す" '[ ! -e "$OLD_PL" ] && [ ! -e "$AG/$U.feedback-mining.plist" ] && [ ! -e "$AG/$U.skill-audit.plist" ] && grep -Fxq "launchctl bootout gui/$UIDN/com.handmade.memory-audit" "$CALLS" && grep -Fxq "launchctl bootout gui/$UIDN/$U.skill-audit" "$CALLS"'
check "台帳を消す" '[ ! -e "$JOBS" ]'
check "launchd に何も残らない" '[ -z "$(ls "$FAKE_LAUNCHD")" ]'
else
  echo "== --with-local と --uninstall: local が無いため飛ばす"
fi
"$REPO/install.sh" --with-schedule </dev/null >/dev/null 2>&1
"$REPO/install.sh" --uninstall >/dev/null 2>&1
check "棚卸しも外す" '[ ! -e "$LOOP_PLIST" ] && [ -z "$(ls "$FAKE_LAUNCHD")" ]'

echo "== --dry-run は何も変えない"
sig="$(tree_sig)"
: >"$CALLS"
if [ "$HAS_LOCAL" -eq 1 ]; then
out="$("$REPO/install.sh" --dry-run --with-local </dev/null 2>&1)"
check "HOME が変わらず launchctl を呼ばない" '[ "$(tree_sig)" = "$sig" ] && [ ! -s "$CALLS" ]'
check "登録する操作を表示する" 'printf "%s" "$out" | grep -q "^\[dry-run\] launchctl bootstrap gui/$UIDN $AG/$U.skill-audit.plist"'
fi
out="$("$REPO/install.sh" --dry-run --with-schedule </dev/null 2>&1)"
check "棚卸しも表示だけ" '[ "$(tree_sig)" = "$sig" ] && printf "%s" "$out" | grep -q "^\[dry-run\] launchctl bootstrap gui/$UIDN $LOOP_PLIST"'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
