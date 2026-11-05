#!/bin/bash
# requires: report-inbox memory-audit feedback-mining skill-audit
# install.sh の「必要なものの確認」の検査。一時の HOME を作る。
# xcode-select・/usr/bin/python3・claude・launchctl を偽のコマンドに差し替え、本物の HOME には触れない。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-prereq-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

FAKEBIN="$WORK/bin"
CLT="$WORK/clt"
mkdir -p "$FAKEBIN" "$CLT/usr/bin"
export CALLS="$WORK/calls.log"
export FAKE_LAUNCHD="$WORK/launchd-registered"
export FAKE_STATE="$WORK/state"
mkdir -p "$FAKE_STATE"

cat >"$FAKEBIN/launchctl" <<'EOF'
#!/bin/bash
printf 'launchctl %s\n' "$*" >>"$CALLS"
case "$1" in
  print) [ -f "$FAKE_LAUNCHD/${2##*/}" ] ;;
  bootstrap) mkdir -p "$FAKE_LAUNCHD" && touch "$FAKE_LAUNCHD/$(plutil -extract Label raw "$3")" ;;
  bootout) rm -f "$FAKE_LAUNCHD/${2##*/}" ;;
esac
EOF
# 偽の xcode-select。FAKE_STATE/clt があればコマンドラインツールがある状態とする。
cat >"$WORK/xcode-select" <<EOF
#!/bin/bash
printf 'xcode-select %s\n' "\$*" >>"\$CALLS"
case "\$1" in
  -p) [ -f "\$FAKE_STATE/clt" ] && echo "$CLT" ;;
  --install) exit 0 ;;
esac
EOF
printf '#!/bin/bash\n' >"$CLT/usr/bin/python3"
# 偽の /usr/bin/python3。呼ばれたことを残す。FAKE_STATE/py-old があれば版の確認で False を返す。
cat >"$WORK/python3" <<'EOF'
#!/bin/bash
printf 'python3 %s\n' "$1" >>"$CALLS"
if [ -f "$FAKE_STATE/py-old" ] && [ "$*" = "-B -c import sys; print(sys.version_info >= (3, 9))" ]; then
  echo False
  exit 0
fi
exec /usr/bin/python3 "$@"
EOF
printf '#!/bin/bash\nprintf "claude %%s\\n" "$*" >>"$CALLS"\n' >"$WORK/claude"
# 検査の側では jq を使う。install.sh からは使わない（呼ばれたら CALLS に残して失敗する）。
JQ="$(command -v jq)"
[ -n "$JQ" ] || { echo "jq が無いため検査できません"; exit 1; }
printf '#!/bin/bash\nprintf "jq %%s\\n" "$*" >>"$CALLS"\nexit 127\n' >"$FAKEBIN/jq"
chmod +x "$FAKEBIN/launchctl" "$WORK/xcode-select" "$CLT/usr/bin/python3" "$WORK/python3" "$WORK/claude" "$FAKEBIN/jq"

export PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin"
export CLAUDE_REVIEW_XCODE_SELECT="$WORK/xcode-select"
export CLAUDE_REVIEW_SYSTEM_PYTHON="$WORK/python3"
unset CLAUDE_REVIEW_PYTHON CLAUDE_REVIEW_LABEL
JOB_PLIST_NAME="com.$(id -un | tr . -).memory-audit.plist"
unset XDG_CONFIG_HOME

# 状態を作り直す。引数: clt / claude のうち、ある状態にするもの。
setup() {
  rm -rf "$WORK/home" "$FAKE_LAUNCHD" "$FAKE_STATE"
  mkdir -p "$FAKE_STATE" "$WORK/home/.claude"
  export HOME="$WORK/home"
  printf '{"model":"opus"}\n' >"$HOME/.claude/settings.json"
  # 見回りの範囲は設定済みにして、必要なものの問いだけを検査する（見回りの範囲の問いは test_install_schedule.sh）。
  mkdir -p "$HOME/.config/claude-review-inbox"
  printf 'PERSONAL_FOLDERS=no\nREPO_ROOTS=\n' >"$HOME/.config/claude-review-inbox/patrol.conf"
  export CLAUDE_REVIEW_CLAUDE_PATHS=""
  local a
  for a in "$@"; do
    case "$a" in
      clt) touch "$FAKE_STATE/clt" ;;
      claude) mkdir -p "$HOME/.local/bin" && cp "$WORK/claude" "$HOME/.local/bin/claude" \
        && export CLAUDE_REVIEW_CLAUDE_PATHS="$HOME/.local/bin/claude" ;;
    esac
  done
  : >"$CALLS"
}

# 標準入力を疑似端末にして install.sh を動かす。$1 は入力する文字列。60 秒で打ち切る。
tty_install() {
  local input="$1"
  shift
  /usr/bin/python3 -B - "$input" "$REPO/install.sh" "$@" <<'PY'
import os, subprocess, sys
m, s = os.openpty()
os.write(m, sys.argv[1].encode())
try:
    p = subprocess.run(sys.argv[2:], stdin=s, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
except subprocess.TimeoutExpired as e:
    sys.stdout.write((e.stdout or b"").decode() + "\nTIMEOUT\n")
    sys.exit(124)
sys.stdout.write(p.stdout.decode())
sys.exit(p.returncode)
PY
}
called() { grep -q "$1" "$CALLS"; }
asked() { printf '%s' "$out" | grep -q "$1"; }
hook_count() { "$JQ" --arg c "$REPO/core/skills/report-inbox/scripts/unread.sh" '[.hooks.SessionStart[]?.hooks[]? | select(.command == $c)] | length' "$1"; }
LEGACY_PLIST() { printf '%s' "$HOME/Library/LaunchAgents/com.$(id -un | tr . -).claude-review-inbox.plist"; }

echo "== 全部そろっているとき"
setup clt claude
out="$(tty_install "" --no-schedule)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "何も聞かない" '! asked "\[y/N\]"'
check "確認の結果を表で出す" 'asked "^必要なものの確認:" && asked "Xcode のコマンドラインツール（必須）: あり" && asked "claude（週1回の見直しに必要）: あり"'
check "何も入れない" '! called "xcode-select --install"'
out="$(tty_install $'y\n')"
check "claude があれば週1回の見直しを聞き、y なら登録する" 'asked "週1回の見直し（memory-audit・feedback-mining・skill-audit" && [ -f "$HOME/Library/LaunchAgents/$JOB_PLIST_NAME" ]'

echo "== コマンドラインツールが無い: y"
setup claude
out="$(tty_install $'y\n')"
rc=$?
check "終了コード2" '[ "$rc" -eq 2 ]'
check "xcode-select --install を呼ぶ" 'called "^xcode-select --install"'
check "入れ終えてから実行し直す旨を出す" 'asked "画面の指示で入れ終えてから、もう一度 ./install.sh を実行してください"'
check "/usr/bin/python3 を実行しない" '! called "^python3"'
check "何も置かない" '[ ! -d "$HOME/Library/LaunchAgents" ] && ! called "^launchctl"'

echo "== コマンドラインツールが無い: N"
setup claude
out="$(tty_install $'n\n')"
rc=$?
check "終了コード2" '[ "$rc" -eq 2 ]'
check "xcode-select --install を呼ばない" '! called "xcode-select --install"'
check "フックを設定できない旨と入れ方を出す" 'asked "フックを設定できません" && asked "xcode-select --install を実行し"'
check "/usr/bin/python3 を実行しない" '! called "^python3"'

echo "== コマンドラインツールが無い: 非端末"
setup claude
out="$("$REPO/install.sh" </dev/null 2>&1)"
rc=$?
check "終了コード2で、入れずに入れ方を出す" '[ "$rc" -eq 2 ] && ! called "xcode-select --install" && asked "xcode-select --install を実行し" && ! called "^python3"'

echo "== コマンドラインツールが無い: --yes"
setup claude
out="$("$REPO/install.sh" --yes </dev/null 2>&1)"
rc=$?
check "聞かずに xcode-select --install を呼び、終了コード2" '[ "$rc" -eq 2 ] && called "^xcode-select --install" && ! asked "\[y/N\]" && ! called "^python3"'

echo "== コマンドラインツールが無い: --dry-run"
setup claude
out="$("$REPO/install.sh" --dry-run --yes </dev/null 2>&1)"
rc=$?
check "入れるものに挙げ、何も入れずに終了コード2" '[ "$rc" -eq 2 ] && asked "  - Xcode のコマンドラインツール（xcode-select --install）" && ! called "xcode-select --install" && ! called "^python3" && [ ! -d "$HOME/Library/LaunchAgents" ]'

echo "== CLAUDE_REVIEW_PYTHON を指定したときはコマンドラインツールを求めない"
setup claude
out="$(CLAUDE_REVIEW_PYTHON=/usr/bin/python3 "$REPO/install.sh" --no-schedule </dev/null 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ] && asked "Xcode のコマンドラインツール（必須）: 不要" && ! called "xcode-select"'

echo "== Python が古い"
setup clt claude
touch "$FAKE_STATE/py-old"
out="$("$REPO/install.sh" </dev/null 2>&1)"
rc=$?
check "終了コード2で、理由と CLAUDE_REVIEW_PYTHON の案内を出す" '[ "$rc" -eq 2 ] && asked "Python 3.9 以上（必須）: 古い" && asked "CLAUDE_REVIEW_PYTHON" && [ ! -d "$HOME/Library/LaunchAgents" ]'

echo "== --dry-run は入れるものが無ければ何も変えない"
setup clt claude
before="$(cd "$HOME" && find . | LC_ALL=C sort)"
out="$("$REPO/install.sh" --dry-run --yes </dev/null 2>&1)"
rc=$?
check "終了コード0で入れるものは無い" '[ "$rc" -eq 0 ] && asked "入れるものはありません" && ! called "^launchctl"'
check "HOME を変えない" '[ "$(cd "$HOME" && find . | LC_ALL=C sort)" = "$before" ]'

echo "== claude が無い"
setup clt
out="$(tty_install "" 2>&1)"
rc=$?
check "週1回の見直しを聞かずに登録しない" '[ "$rc" -eq 0 ] && ! asked "週1回の見直し（memory-audit" && asked "claude が見つからないため、週1回の見直しは登録しません" && [ ! -e "$HOME/Library/LaunchAgents/$JOB_PLIST_NAME" ]'
out="$("$REPO/install.sh" --with-schedule </dev/null 2>&1)"
check "--with-schedule でも登録しない" '[ ! -e "$HOME/Library/LaunchAgents/$JOB_PLIST_NAME" ]'

echo "== jq を使わずにフックを足し・外す"
setup clt claude
"$REPO/install.sh" --no-schedule </dev/null >/dev/null 2>&1
check "フックを足し、既存の設定を残す" '[ "$(hook_count "$HOME/.claude/settings.json")" = "1" ] && [ "$("$JQ" -r .model "$HOME/.claude/settings.json")" = "opus" ]'
"$REPO/install.sh" --uninstall </dev/null >/dev/null 2>&1
check "フックを外し、空になった hooks を消す" '[ "$(hook_count "$HOME/.claude/settings.json")" = "0" ] && [ "$("$JQ" "has(\"hooks\")" "$HOME/.claude/settings.json")" = "false" ] && [ "$("$JQ" -r .model "$HOME/.claude/settings.json")" = "opus" ]'
rm -f "$HOME/.claude/settings.json"
"$REPO/install.sh" --no-schedule </dev/null >/dev/null 2>&1
check "settings.json が無ければ作る" '[ "$(hook_count "$HOME/.claude/settings.json")" = "1" ]'
check "jq を一度も呼ばない" '! called "^jq"'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
