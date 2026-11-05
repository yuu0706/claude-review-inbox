#!/bin/bash
# requires: memory-audit feedback-mining skill-audit weakness-review repo-patrol secret-patrol
# install.sh の定期実行（週1回の見直しの3つ）と見回りの範囲（patrol.conf）の検査。
# 一時の HOME を作り、launchctl を偽のコマンドに差し替えて実行する。本物の HOME・launchctl には触れない。
set -u
# 2つ目の設定ディレクトリの名前。利用者の環境の名前を書かないよう、中立な名前を変数で持つ。
ALT_DIR=.claude_alt

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-install-schedule-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽の launchctl。呼ばれた引数を CALLS へ記録し、登録の状態をラベルごとのファイルで持つ。
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
export CALLS="$WORK/calls.log"
: >"$CALLS"
export FAKE_LAUNCHD="$WORK/launchd-registered"
mkdir -p "$FAKE_LAUNCHD"
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
# 必要なものの確認: 本物の xcode-select・claude を見ないように差し替える。claude は偽物を置く。
mkdir -p "$WORK/clt/usr/bin"
printf '#!/bin/bash\n' >"$WORK/clt/usr/bin/python3"
printf '#!/bin/bash\n[ "$1" = "-p" ] && echo "%s"\n' "$WORK/clt" >"$WORK/xcode-select"
printf '#!/bin/bash\nexit 0\n' >"$FAKEBIN/claude"
chmod +x "$WORK/clt/usr/bin/python3" "$WORK/xcode-select" "$FAKEBIN/claude"
export CLAUDE_REVIEW_XCODE_SELECT="$WORK/xcode-select"
export CLAUDE_REVIEW_CLAUDE_PATHS=""
export PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin"

export HOME="$WORK/home"
unset CLAUDE_REVIEW_LABEL CLAUDE_REVIEW_PYTHON XDG_CONFIG_HOME
mkdir -p "$HOME/.claude" "$HOME/${ALT_DIR}/skills"
ln -s ../${ALT_DIR}/skills "$HOME/.claude/skills"
printf '{}\n' >"$HOME/.claude/settings.json"
S2="$HOME/${ALT_DIR}/skills"
AG="$HOME/Library/LaunchAgents"
U="com.$(id -un | tr . -)"
JOBS="$HOME/.local/state/claude-review-inbox/scheduled-jobs.tsv"
CONF="$HOME/.config/claude-review-inbox/patrol.conf"
UIDN="$(id -u)"
Q_SCHEDULE="週1回の見直し（memory-audit・feedback-mining・skill-audit・weakness-review）を登録しますか。claude の利用枠を使います [y/N]"
Q_PERSONAL="書類・デスクトップ・ダウンロードのフォルダを、個人情報の置き忘れの見回りに入れますか。初めて見回るときに、macOS がフォルダへのアクセスの許可を求めます [y/N]"
Q_REPOS="手元のリポジトリを置いているフォルダを入力してください（例: ~/Documents/git。空なら見回りません）"

# 標準入力を疑似端末にして install.sh を動かす。$1 は入力する文字列。
tty_install() {
  local input="$1"
  shift
  /usr/bin/python3 -B - "$input" "$REPO/install.sh" "$@" <<'PY'
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
has() { printf '%s' "$out" | grep -Fq -- "$1"; }
no_jobs() { [ ! -e "$AG/$U.memory-audit.plist" ] && [ ! -e "$AG/$U.feedback-mining.plist" ] && [ ! -e "$AG/$U.skill-audit.plist" ] && [ ! -e "$AG/$U.weakness-review.plist" ]; }

echo "== 非端末で指定なし"
out="$("$REPO/install.sh" </dev/null 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "聞かない" '! printf "%s" "$out" | grep -q "\[y/N\]"'
check "定期実行を登録しない" 'no_jobs && ! grep -q "bootstrap.*memory-audit" "$CALLS"'
check "見回りの範囲の設定ファイルを書かない" '[ ! -e "$CONF" ] && has "見回りの範囲を聞かず、設定ファイルも書きません"'

echo "== 聞かれて n（見回りの範囲も聞く）"
: >"$CALLS"
out="$(tty_install $'n\nn\n\n')"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "定期実行の問いの文言" 'has "$Q_SCHEDULE"'
check "登録しない" 'no_jobs'
check "見回りの範囲の2つの問いを出す" 'has "$Q_PERSONAL" && has "$Q_REPOS"'
check "答えを設定ファイルに書く（入れない・見回らない）" 'grep -qx "PERSONAL_FOLDERS=no" "$CONF" && grep -qx "REPO_ROOTS=" "$CONF"'

echo "== 聞かれて y（設定ファイルがあれば見回りの範囲は聞かない）"
: >"$CALLS"
conf_before="$(cat "$CONF")"
out="$(tty_install $'y\n')"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "見回りの範囲は聞かない" '! has "$Q_PERSONAL" && has "見回りの範囲は設定済みです" && [ "$(cat "$CONF")" = "$conf_before" ]'
check "4つの plist を作る" '[ -f "$AG/$U.memory-audit.plist" ] && [ -f "$AG/$U.feedback-mining.plist" ] && [ -f "$AG/$U.skill-audit.plist" ] && [ -f "$AG/$U.weakness-review.plist" ]'
check "起動スクリプトはスキル置き場の中" '[ "$(px "$AG/$U.memory-audit.plist" ProgramArguments.1)" = "$S2/memory-audit/scripts/run.sh" ] && [ "$(px "$AG/$U.feedback-mining.plist" ProgramArguments.1)" = "$S2/feedback-mining/scripts/run.sh" ] && [ "$(px "$AG/$U.skill-audit.plist" ProgramArguments.1)" = "$S2/skill-audit/scripts/run-audit.sh" ] && [ "$(px "$AG/$U.weakness-review.plist" ProgramArguments.1)" = "$S2/weakness-review/scripts/run.sh" ]'
check "時刻はひな形のまま（memory-audit 10:30・feedback-mining 11:00・skill-audit 10:00・weakness-review 12:00）" '[ "$(px "$AG/$U.memory-audit.plist" StartCalendarInterval.Minute)" = "30" ] && [ "$(px "$AG/$U.feedback-mining.plist" StartCalendarInterval.Hour)" = "11" ] && [ "$(px "$AG/$U.skill-audit.plist" StartCalendarInterval.Hour)" = "10" ] && [ "$(px "$AG/$U.weakness-review.plist" StartCalendarInterval.Hour)" = "12" ]'
check "launchctl bootstrap で登録する" 'grep -Fxq "launchctl bootstrap gui/$UIDN $AG/$U.skill-audit.plist" "$CALLS"'
check "台帳に4つを記録する" '[ "$(wc -l <"$JOBS" | tr -d " ")" = "4" ] && grep -q "^memory-audit	$U.memory-audit	$AG/$U.memory-audit.plist	0$" "$JOBS"'

echo "== --no-schedule は登録済みの4つを外す"
: >"$CALLS"
out="$("$REPO/install.sh" --no-schedule </dev/null 2>&1)"
check "plist を消し、bootout する" 'no_jobs && grep -Fxq "launchctl bootout gui/$UIDN/$U.feedback-mining" "$CALLS"'
check "台帳から消す" '[ ! -f "$JOBS" ] || ! grep -q "audit\|mining\|weakness" "$JOBS"'

echo "== --with-schedule"
: >"$CALLS"
out="$("$REPO/install.sh" --with-schedule </dev/null 2>&1)"
rc=$?
check "終了コード0で聞かない" '[ "$rc" -eq 0 ] && ! printf "%s" "$out" | grep -q "\[y/N\]"'
check "4つを登録する" '[ -f "$AG/$U.memory-audit.plist" ] && [ -f "$AG/$U.skill-audit.plist" ] && [ -f "$AG/$U.weakness-review.plist" ]'
sig="$(tree_sig)"
: >"$CALLS"
"$REPO/install.sh" --with-schedule </dev/null >/dev/null 2>&1
check "2回実行しても HOME が同じ" '[ "$(tree_sig)" = "$sig" ]'
check "登録済みなら bootout してから bootstrap する" '[ "$(grep "skill-audit" "$CALLS" | grep "^launchctl boot" | cut -d" " -f2 | tr "\n" " ")" = "bootout bootstrap " ]'
"$REPO/install.sh" --with-schedule --no-schedule >/dev/null 2>&1
check "--with-schedule と --no-schedule の同時指定は終了コード2" '[ $? -eq 2 ]'
"$REPO/install.sh" --no-schedule </dev/null >/dev/null 2>&1

echo "== claude が無ければ聞かずに登録しない"
mv "$FAKEBIN/claude" "$WORK/claude.unused"
out="$(tty_install $'y\n')"
check "聞かず、登録しない" '! has "$Q_SCHEDULE" && no_jobs && has "週1回の見直しは登録しません"'
mv "$WORK/claude.unused" "$FAKEBIN/claude"

echo "== 既存のラベルの引き継ぎ"
# 別のラベルで memory-audit を手で登録してある状態を作る。
mkdir -p "$AG"
OLD_PL="$AG/com.handmade.memory-audit.plist"
sed -e "s|@@LABEL@@|com.handmade.memory-audit|" -e "s|@@SCRIPT@@|$S2/memory-audit/scripts/run.sh|" -e "s|@@HOME@@|/old/home|g" \
  "$REPO/core/skills/memory-audit/launchd/memory-audit.plist.template" >"$OLD_PL"
old_sum="$(shasum -a 256 <"$OLD_PL")"
touch "$FAKE_LAUNCHD/com.handmade.memory-audit"
# install.sh の外で weakness-review を登録してある状態（台帳に載っていない）も、同じくラベルを引き継ぐ。
OLD_WR="$AG/com.handmade.weakness-review.plist"
sed -e "s|@@LABEL@@|com.handmade.weakness-review|" -e "s|@@SCRIPT@@|$S2/weakness-review/scripts/run.sh|" -e "s|@@HOME@@|$HOME|g" \
  "$REPO/core/skills/weakness-review/launchd/weakness-review.plist.template" >"$OLD_WR"
touch "$FAKE_LAUNCHD/com.handmade.weakness-review"
: >"$CALLS"
out="$("$REPO/install.sh" --with-schedule </dev/null 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "既存のラベルを引き継ぐ（二重に登録しない）" '[ ! -e "$AG/$U.memory-audit.plist" ] && [ "$(px "$OLD_PL" Label)" = "com.handmade.memory-audit" ] && has "既存のラベルを引き継ぎます: com.handmade.memory-audit"'
check "引き継いだ plist を書き換え、bootout してから bootstrap する" '[ "$(px "$OLD_PL" StandardOutPath)" = "$HOME/.local/state/claude-reports/memory-audit/launchd.stdout.log" ] && [ "$(grep "handmade.memory-audit" "$CALLS" | grep "^launchctl boot" | cut -d" " -f2 | tr "\n" " ")" = "bootout bootstrap " ]'
bk="$(ls "$HOME/.local/state/claude-review-inbox/plist-backup/"*/com.handmade.memory-audit.plist 2>/dev/null | head -1)"
check "書き換える前の plist を複製する" '[ -n "$bk" ] && [ "$(shasum -a 256 <"$bk")" = "$old_sum" ]'
check "台帳に引き継ぎの印をつける" 'grep -q "^memory-audit	com.handmade.memory-audit	$OLD_PL	1$" "$JOBS"'

check "weakness-review: 既存のラベルを引き継ぐ（二重に登録しない）" '[ ! -e "$AG/$U.weakness-review.plist" ] && [ "$(px "$OLD_WR" Label)" = "com.handmade.weakness-review" ] && has "既存のラベルを引き継ぎます: com.handmade.weakness-review"'
check "weakness-review: 台帳に引き継ぎの印をつける" 'grep -q "^weakness-review	com.handmade.weakness-review	$OLD_WR	1$" "$JOBS"'

echo "== 旧版の review-loop の後始末"
OLD_LOOP="$AG/$U.review-loop.plist"
cp "$AG/$U.skill-audit.plist" "$OLD_LOOP"
plutil -replace Label -string "$U.review-loop" "$OLD_LOOP"
touch "$FAKE_LAUNCHD/$U.review-loop"
printf 'review-loop\t%s\t%s\t0\n' "$U.review-loop" "$OLD_LOOP" >>"$JOBS"
ln -s "$REPO/core/skills/review-loop" "$S2/review-loop"
: >"$CALLS"
out="$("$REPO/install.sh" --with-schedule </dev/null 2>&1)"
check "旧版の定期実行を外す" '[ ! -e "$OLD_LOOP" ] && grep -Fxq "launchctl bootout gui/$UIDN/$U.review-loop" "$CALLS" && ! grep -q "^review-loop" "$JOBS"'
check "旧版のリンクを外す（.trash へ移さない）" '[ ! -L "$S2/review-loop" ] && [ -z "$(ls -d "$S2/.trash/"*-review-loop 2>/dev/null)" ]'
mkdir -p "$WORK/elsewhere/review-loop"
ln -s "$WORK/elsewhere/review-loop" "$S2/review-loop"
"$REPO/install.sh" --with-schedule </dev/null >/dev/null 2>&1
check "他を指す review-loop のリンクは消さない" '[ -L "$S2/review-loop" ]'
rm -f "$S2/review-loop"

echo "== --uninstall"
cp "$AG/$U.skill-audit.plist" "$OLD_LOOP"
plutil -replace Label -string "$U.review-loop" "$OLD_LOOP"
touch "$FAKE_LAUNCHD/$U.review-loop"
printf 'review-loop\t%s\t%s\t0\n' "$U.review-loop" "$OLD_LOOP" >>"$JOBS"
: >"$CALLS"
out="$("$REPO/install.sh" --uninstall 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "引き継いだラベルを外す前に表示する" 'has "定期実行を外します（既存のラベルを引き継いだもの）: com.handmade.memory-audit"'
check "3つと旧版の review-loop を外す" '[ ! -e "$OLD_PL" ] && no_jobs && [ ! -e "$OLD_LOOP" ] && grep -Fxq "launchctl bootout gui/$UIDN/$U.review-loop" "$CALLS"'
check "台帳を消す" '[ ! -e "$JOBS" ]'
check "launchd に何も残らない" '[ -z "$(ls "$FAKE_LAUNCHD")" ]'
check "見回りの範囲の設定ファイルは残す" '[ -f "$CONF" ]'

echo "== 見回りの範囲: 書類などを入れ、リポジトリの置き場所を答える"
rm -f "$CONF"
out="$(tty_install $'n\ny\n~/Documents/git\n')"
check "答えを設定ファイルに書く" 'grep -qx "PERSONAL_FOLDERS=yes" "$CONF" && grep -qx "REPO_ROOTS=~/Documents/git" "$CONF"'
check "書類の下のフォルダには許可のダイアログが出ることを表示する" 'has "~/Documents/git は書類・デスクトップ・ダウンロードの下にあるため、初めて見回るときに macOS がフォルダへのアクセスの許可を求めます"'
rm -f "$CONF"
out="$(tty_install $'n\nn\n/opt/repos\n')"
check "書類の外のフォルダには許可の表示をしない" 'grep -qx "REPO_ROOTS=/opt/repos" "$CONF" && ! has "/opt/repos は"'
rm -f "$CONF"
out="$("$REPO/install.sh" --yes </dev/null 2>&1)"
check "--yes は聞かずに「入れない・見回らない」" '! has "$Q_PERSONAL" && grep -qx "PERSONAL_FOLDERS=no" "$CONF" && grep -qx "REPO_ROOTS=" "$CONF"'
printf 'PERSONAL_FOLDERS=yes\nREPO_ROOTS=/x\n' >"$CONF"
out="$("$REPO/install.sh" --yes </dev/null 2>&1)"
check "既にあれば --yes でも書き換えない" '[ "$(cat "$CONF")" = "$(printf "PERSONAL_FOLDERS=yes\nREPO_ROOTS=/x")" ]'
XC="$WORK/xdg"
out="$(XDG_CONFIG_HOME="$XC" "$REPO/install.sh" --yes </dev/null 2>&1)"
check "XDG_CONFIG_HOME の下に書く" '[ -f "$XC/claude-review-inbox/patrol.conf" ]'

echo "== --dry-run は何も変えず、聞く内容と操作を表示する"
rm -f "$CONF"
"$REPO/install.sh" --uninstall >/dev/null 2>&1
sig="$(tree_sig)"
: >"$CALLS"
out="$("$REPO/install.sh" --dry-run </dev/null 2>&1)"
check "HOME が変わらず launchctl を呼ばない" '[ "$(tree_sig)" = "$sig" ] && [ ! -s "$CALLS" ]'
check "定期実行の問いと、y のときの3つの登録を表示する" 'has "[dry-run] 聞く: $Q_SCHEDULE" && has "[dry-run] launchctl bootstrap gui/$UIDN $AG/$U.memory-audit.plist" && has "[dry-run] launchctl bootstrap gui/$UIDN $AG/$U.feedback-mining.plist" && has "[dry-run] launchctl bootstrap gui/$UIDN $AG/$U.skill-audit.plist"'
check "見回りの範囲の問いと書き先を表示する" 'has "[dry-run] 聞く: $Q_PERSONAL" && has "[dry-run] 聞く: $Q_REPOS" && has "[dry-run] 答えを書く: $CONF"'
check "3つのフックを表示する" 'has "unread.sh）" && has "run-if-due.sh）" && has "session-trigger.sh）"'
out="$("$REPO/install.sh" --dry-run --no-schedule </dev/null 2>&1)"
check "--no-schedule の --dry-run は問いを表示しない" '! has "$Q_SCHEDULE"'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
