#!/bin/bash
# install.sh の検査。一時の HOME を作り、launchctl と brew を偽のコマンドに差し替えて実行する。
# 本物の HOME・launchctl・brew には触れない。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-install-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽のコマンド。呼ばれた引数を CALLS へ記録する。launchctl は登録の状態をファイルで持つ。
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
export CALLS="$WORK/calls.log"
export FAKE_LAUNCHD="$WORK/launchd-registered"
cat >"$FAKEBIN/launchctl" <<'EOF'
#!/bin/bash
printf 'launchctl %s\n' "$*" >>"$CALLS"
# 登録の状態はラベルごとのファイルで持つ。
case "$1" in
  print) [ -f "$FAKE_LAUNCHD/${2##*/}" ] ;;
  bootstrap) mkdir -p "$FAKE_LAUNCHD" && touch "$FAKE_LAUNCHD/$(plutil -extract Label raw "$3")" ;;
  bootout) rm -f "$FAKE_LAUNCHD/${2##*/}" ;;
esac
EOF
cat >"$FAKEBIN/brew" <<'EOF'
#!/bin/bash
printf 'brew %s\n' "$*" >>"$CALLS"
[ "$1" = "--prefix" ] && printf '%s\n' "$FAKE_TN_PREFIX"
exit 0
EOF
# open はアプリとして起動したことを記録し、以後の terminal-notifier を成功させる（許可された状態を模す）。
cat >"$FAKEBIN/open" <<'EOF'
#!/bin/bash
printf 'open %s\n' "$*" >>"$CALLS"
echo opened >"$FAKE_TN_STATE"
EOF
# 偽の terminal-notifier。FAKE_TN_STATE の内容が allowed か opened なら成功し、それ以外は終了コード 3 で失敗する。
# 置くのは試しの通知の検査のときだけ（tn_mode で置く）。
cat >"$WORK/terminal-notifier" <<'EOF'
#!/bin/bash
printf 'terminal-notifier %s\n' "$*" >>"$CALLS"
case "$(cat "$FAKE_TN_STATE" 2>/dev/null)" in allowed|opened) exit 0 ;; esac
echo "Could not request notification permission: Notifications are not allowed for this application" >&2
exit 3
EOF
chmod +x "$FAKEBIN/launchctl" "$FAKEBIN/brew" "$FAKEBIN/open" "$WORK/terminal-notifier"
export FAKE_TN_PREFIX="$WORK/Cellar/terminal-notifier/3.1.0"
export FAKE_TN_STATE="$WORK/tn-state"
mkdir -p "$FAKE_TN_PREFIX/terminal-notifier.app"
# $1: allowed=許可済み / denied=アプリとして起動するまで失敗 / never=起動しても失敗
tn_mode() {
  ln -sfn "$WORK/terminal-notifier" "$FAKEBIN/terminal-notifier"
  echo "$1" >"$FAKE_TN_STATE"
  if [ "$1" = "never" ]; then
    printf '#!/bin/bash\nprintf "open %%s\\n" "$*" >>"$CALLS"\n' >"$FAKEBIN/open"
  fi
}
JQ="$(command -v jq)"
if [ -z "$JQ" ]; then
  echo "jq が無いため検査できません"
  exit 1
fi
ln -s "$JQ" "$FAKEBIN/jq"
export PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin"

# 偽の HOME。~/.claude/skills は ~/.claude2/skills へのリンク（利用者の環境と同じ形）。
export HOME="$WORK/home"
# 公開版（local が無い版）では、local を前提にした検査を飛ばす。
HAS_LOCAL=0
[ -d "$REPO/local/skills" ] && HAS_LOCAL=1
WL=()
[ "$HAS_LOCAL" -eq 1 ] && WL=(--with-local)
repo_skills() { local s; for s in "$REPO"/core/skills/* "$REPO"/local/skills/*; do [ -d "$s" ] && printf '%s\n' "$s"; done; }
unset CLAUDE_REVIEW_LABEL CLAUDE_REVIEW_PORT CLAUDE_REVIEW_PYTHON
mkdir -p "$HOME/.claude" "$HOME/.claude2/skills/other-skill" "$HOME/.claude2/skills/change-review"
ln -s ../.claude2/skills "$HOME/.claude/skills"
echo "old" >"$HOME/.claude2/skills/change-review/SKILL.md"
printf '{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/other/hook.sh"}]}]}}\n' >"$HOME/.claude/settings.json"
printf '{"theme":"dark"}\n' >"$HOME/.claude2/settings.json"
S2="$HOME/.claude2/skills"
LABEL="com.$(id -un | tr . -).claude-review-inbox"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOOK="$REPO/core/hooks/session-start.sh"
hook_count() { jq --arg c "$HOOK" '[.hooks.SessionStart[]?.hooks[]? | select(.command == $c)] | length' "$1"; }
# HOME の中身の一覧（パス・種類・リンク先・内容のハッシュ）。変化の有無を比べるのに使う。
tree_sig() {
  (cd "$HOME" && find . \( -type f -o -type l -o -type d \) -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"
    elif [ -f "$f" ]; then printf 'F %s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
    else printf 'D %s\n' "$f"; fi
  done)
}

echo "== --dry-run は何も変えない"
before="$(tree_sig)"
out="$("$REPO/install.sh" --dry-run 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "HOME が変わらない" '[ "$(tree_sig)" = "$before" ]'
check "launchctl・brew を呼ばない" '[ ! -s "$CALLS" ]'
check "試しの通知の操作は表示だけにする" 'printf "%s" "$out" | grep -q "^\[dry-run\] （terminal-notifier があれば）試しの通知"'
check "行う操作を表示する" 'printf "%s" "$out" | grep -q "^\[dry-run\] ln -s $REPO/core/skills/change-review" && printf "%s" "$out" | grep -q "^\[dry-run\] brew install terminal-notifier"'

echo "== 本体だけ"
out="$("$REPO/install.sh" 2>&1)"
rc=$?
printf '%s\n' "$out" | tail -3
check "終了コード0" '[ "$rc" -eq 0 ]'
check "brew で terminal-notifier を入れる" 'grep -Fxq "brew install terminal-notifier" "$CALLS"'
check "change-review がリポジトリへのリンクになる" '[ -L "$S2/change-review" ] && [ "$(readlink "$S2/change-review")" = "$REPO/core/skills/change-review" ]'
trashed="$(ls -d "$S2/.trash/"*-change-review 2>/dev/null)"
check "既存の実体は .trash/<日時>-<名前> へ退避する" '[ -f "$trashed/SKILL.md" ] && [[ "${trashed##*/}" =~ ^[0-9]{8}-[0-9]{6}-change-review$ ]]'
check "同じ実体へ二重に置かない（.claude/skills はリンクのまま）" '[ -L "$HOME/.claude/skills" ] && [ "$(ls "$S2/.trash" | wc -l | tr -d " ")" = "1" ]'
check "local のスキルは入れない" '[ ! -e "$S2/memory-audit" ] && [ ! -e "$S2/report-inbox" ]'
check "本体だけでは review-loop をリンクする" '[ -L "$S2/review-loop" ] && [ "$(readlink "$S2/review-loop")" = "$REPO/core/skills/review-loop" ]'
check "他のスキルに触れない" '[ -d "$S2/other-skill" ] && [ ! -L "$S2/other-skill" ]'
check "plist を作る" '[ -f "$PLIST" ] && plutil -lint "$PLIST" >/dev/null'
check "plist のラベル・サーバー・常駐の設定" '[ "$(plutil -extract Label raw "$PLIST")" = "$LABEL" ] && [ "$(plutil -extract ProgramArguments.1 raw "$PLIST")" = "$REPO/core/server/inbox_server.py" ] && [ "$(plutil -extract ProgramArguments.0 raw "$PLIST")" = "/usr/bin/python3" ] && [ "$(plutil -extract RunAtLoad raw "$PLIST")" = "true" ] && [ "$(plutil -extract KeepAlive raw "$PLIST")" = "true" ] && [ "$(plutil -extract EnvironmentVariables.CLAUDE_REVIEW_PORT raw "$PLIST")" = "8010" ]'
check "ログの置き場所を状態の置き場所にする" '[ "$(plutil -extract StandardOutPath raw "$PLIST")" = "$HOME/.local/state/claude-review-inbox/server.log" ]'
check "launchctl bootstrap で登録する" 'grep -Fxq "launchctl bootstrap gui/$(id -u) $PLIST" "$CALLS"'
check "未登録なら bootout しない" '! grep -q "launchctl bootout" "$CALLS"'
check "両方の settings.json にフックを1つ足す" '[ "$(hook_count "$HOME/.claude/settings.json")" = "1" ] && [ "$(hook_count "$HOME/.claude2/settings.json")" = "1" ]'
check "既存の設定を消さない" '[ "$(jq -r .model "$HOME/.claude/settings.json")" = "opus" ] && [ "$(jq -r ".hooks.SessionStart[0].hooks[0].command" "$HOME/.claude/settings.json")" = "/other/hook.sh" ] && [ "$(jq -r .theme "$HOME/.claude2/settings.json")" = "dark" ]'
check "書き換える前に settings.json.bak-<日時> を残す" '[ "$(ls "$HOME/.claude/"settings.json.bak-* | wc -l | tr -d " ")" = "1" ] && grep -q "/other/hook.sh" "$HOME/.claude/"settings.json.bak-* && ! grep -q "session-start.sh" "$HOME/.claude/"settings.json.bak-*'
check "案と状態の置き場所を作る" '[ -d "$HOME/claude-reports/proposals" ] && [ -d "$HOME/.local/state/claude-review-inbox" ]'
check "最後に URL と通知の許可の案内を出す" 'printf "%s" "$out" | grep -Fq "http://127.0.0.1:8010/" && printf "%s" "$out" | grep -q "5. 通知の許可"'

echo "== 2回実行しても同じ"
sig1="$(tree_sig)"
: >"$CALLS"
"$REPO/install.sh" >/dev/null 2>&1
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "HOME の中身が同じ（退避・バックアップが増えない）" '[ "$(tree_sig)" = "$sig1" ]'
check "登録済みなら bootout してから bootstrap する" '[ "$(cat "$CALLS" | grep "^launchctl boot" | cut -d" " -f2 | tr "\n" " ")" = "bootout bootstrap " ]'

if [ "$HAS_LOCAL" -eq 1 ]; then
echo "== --with-local"
mkdir -p "$S2/memory-audit"
echo "old" >"$S2/memory-audit/SKILL.md"
: >"$CALLS"
check "--with-local の前は review-loop のリンクがある" '[ -L "$S2/review-loop" ]'
out="$("$REPO/install.sh" --with-local 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
ok_links=1
for s in "$REPO"/core/skills/* "$REPO"/local/skills/*; do
  n="${s##*/}"
  [ "$n" = "review-loop" ] && continue
  [ -L "$S2/$n" ] && [ "$(readlink "$S2/$n")" = "$s" ] || ok_links=0
done
check "review-loop 以外の core と local の全スキルがリンクになる" '[ "$ok_links" -eq 1 ]'
check "--with-local では既存の review-loop のリンクを外す" '[ ! -e "$S2/review-loop" ] && [ ! -L "$S2/review-loop" ] && printf "%s" "$out" | grep -Fq "リンクを消しました（--with-local では review-loop を入れない）: $S2/review-loop"'
check "外した review-loop は .trash へ移さない" '[ -z "$(ls -d "$S2/.trash/"*-review-loop 2>/dev/null)" ]'
check "local の既存の実体も退避する" '[ -f "$(ls -d "$S2/.trash/"*-memory-audit)/SKILL.md" ]'
check "--with-local では本体のフックを外す（report-inbox が件数を出す）" '[ "$(hook_count "$HOME/.claude/settings.json")" = "0" ] && [ "$(hook_count "$HOME/.claude2/settings.json")" = "0" ]'
check "外しても他のフックと設定は残る" '[ "$(jq -r ".hooks.SessionStart[0].hooks[0].command" "$HOME/.claude/settings.json")" = "/other/hook.sh" ] && [ "$(jq -r .theme "$HOME/.claude2/settings.json")" = "dark" ] && [ "$(jq "has(\"hooks\")" "$HOME/.claude2/settings.json")" = "false" ]'
sig2="$(tree_sig)"
"$REPO/install.sh" --with-local >/dev/null 2>&1
check "--with-local も2回目で変わらない" '[ "$(tree_sig)" = "$sig2" ]'

echo "== --with-local（review-loop のリンクが無い状態から）"
rm -f "$S2/review-loop"
"$REPO/install.sh" --with-local >/dev/null 2>&1
check "--with-local では review-loop のリンクを作らない" '[ ! -e "$S2/review-loop" ] && [ ! -L "$S2/review-loop" ]'
out="$("$REPO/install.sh" --with-local --dry-run 2>&1)"
check "--with-local の --dry-run は review-loop を置く操作を表示しない" '! printf "%s" "$out" | grep -q "core/skills/review-loop"'
mkdir -p "$WORK/elsewhere/review-loop"
ln -s "$WORK/elsewhere/review-loop" "$S2/review-loop"
"$REPO/install.sh" --with-local >/dev/null 2>&1
check "--with-local でも他を指す review-loop のリンクは消さない" '[ -L "$S2/review-loop" ] && [ "$(readlink "$S2/review-loop")" = "$WORK/elsewhere/review-loop" ]'
rm -f "$S2/review-loop"

else
  echo "== --with-local: local が無いため飛ばす"
fi

echo "== --uninstall"
: >"$CALLS"
"$REPO/install.sh" >/dev/null 2>&1  # 本体のフックを足し直してから外す
: >"$CALLS"
out="$("$REPO/install.sh" --uninstall 2>&1)"
rc=$?
printf '%s\n' "$out" | tail -5
check "終了コード0" '[ "$rc" -eq 0 ]'
check "launchd から外す" 'grep -Fxq "launchctl bootout gui/$(id -u)/$LABEL" "$CALLS" && [ ! -e "$FAKE_LAUNCHD/$LABEL" ]'
check "plist を消す" '[ ! -e "$PLIST" ]'
check "リポジトリを指すリンクだけを消す" '[ -z "$(find "$S2" -maxdepth 1 -type l)" ] && [ -d "$S2/other-skill" ] && [ -L "$HOME/.claude/skills" ]'
check "足したフックを消し、他の設定は残す" '[ "$(hook_count "$HOME/.claude/settings.json")" = "0" ] && [ "$(jq -r .model "$HOME/.claude/settings.json")" = "opus" ] && [ "$(jq -r ".hooks.SessionStart[0].hooks[0].command" "$HOME/.claude/settings.json")" = "/other/hook.sh" ]'
check "退避したものは戻さず、戻し方を表示する" '[ -d "$(ls -d "$S2/.trash/"*-change-review)" ] && printf "%s" "$out" | grep -Fq "mv '"'"'$(ls -d "$S2/.trash/"*-change-review)'"'"' '"'"'$S2/change-review'"'"'"'
check "案と状態の置き場所は残す" '[ -d "$HOME/claude-reports/proposals" ] && [ -d "$HOME/.local/state/claude-review-inbox" ]'
sig3="$(tree_sig)"
"$REPO/install.sh" --uninstall >/dev/null 2>&1
rc=$?
check "2回外しても終了コード0で変わらない" '[ "$rc" -eq 0 ] && [ "$(tree_sig)" = "$sig3" ]'

echo "== リンクの張り直し（リポジトリを移し、旧位置に新位置へのリンクを置いた）"
OLDREPO="$WORK/old-location/claude-review-inbox"
mkdir -p "$(dirname "$OLDREPO")"
ln -s "$REPO" "$OLDREPO"
# リポジトリのスキルへのリンクを、旧位置を経由する形に置き換える。
relink_via_old() {
  local s
  while IFS= read -r s; do
    ln -sfn "$OLDREPO/${s#"$REPO"/}" "$S2/${s##*/}"
  done < <(repo_skills)
}
"$REPO/install.sh" ${WL[@]+"${WL[@]}"} >/dev/null 2>&1
relink_via_old
trash_before="$(ls "$S2/.trash" | wc -l | tr -d " ")"
out="$("$REPO/install.sh" ${WL[@]+"${WL[@]}"} 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
ok_links=1
while IFS= read -r s; do
  [ "$HAS_LOCAL" -eq 1 ] && [ "${s##*/}" = "review-loop" ] && continue
  [ "$(readlink "$S2/${s##*/}")" = "$s" ] || ok_links=0
done < <(repo_skills)
check "旧位置を指すリンクを新位置へ張り直す" '[ "$ok_links" -eq 1 ]'
[ "$HAS_LOCAL" -eq 1 ] && check "旧位置を経由する review-loop のリンクも --with-local では外す" '[ ! -L "$S2/review-loop" ]'
check "張り直したと表示する" 'printf "%s" "$out" | grep -Fq "リンクを張り直しました: $S2/change-review（旧: $OLDREPO/core/skills/change-review）"'
check "張り直しでは .trash へ退避しない" '[ "$(ls "$S2/.trash" | wc -l | tr -d " ")" = "$trash_before" ]'
check "リポジトリの中にリンクを作らない" '[ ! -L "$REPO/core/skills/change-review/change-review" ]'
relink_via_old
"$REPO/install.sh" --uninstall >/dev/null 2>&1
check "--uninstall は旧位置を経由したリンクも外す" '[ -z "$(find "$S2" -maxdepth 1 -type l)" ] && [ -d "$S2/other-skill" ]'
ln -s "$WORK/elsewhere/change-review" "$S2/change-review"
"$REPO/install.sh" --uninstall >/dev/null 2>&1
check "--uninstall は他を指すリンクを外さない" '[ -L "$S2/change-review" ]'
mv -f "$S2/change-review" "$WORK/elsewhere-link"

echo "== 試しの通知: 許可済み"
tn_mode allowed
: >"$CALLS"
out="$("$REPO/install.sh" 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "brew install を呼ばない" '! grep -q "^brew install" "$CALLS"'
check "試しの通知を1回出す" '[ "$(grep -c "^terminal-notifier " "$CALLS")" = "1" ] && grep -Fq "terminal-notifier -title claude-review-inbox -message claude-review-inbox の通知の確認です" "$CALLS"'
check "アプリとして起動しない" '! grep -q "^open" "$CALLS"'

echo "== 試しの通知: アプリとして起動すると成功する"
tn_mode denied
: >"$CALLS"
out="$("$REPO/install.sh" 2>&1)"
rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "brew --prefix で求めた場所のアプリを open -W -a で起動する" 'grep -Fxq "open -W -a $FAKE_TN_PREFIX/terminal-notifier.app --args -title claude-review-inbox -message claude-review-inbox の通知の確認です" "$CALLS"'
check "起動の後にもう一度試す" '[ "$(grep -c "^terminal-notifier " "$CALLS")" = "2" ]'
check "成功を表示し、許可の手順は出さない" 'printf "%s" "$out" | grep -q "試しの通知を出しました（terminal-notifier をアプリとして起動した後）" && ! printf "%s" "$out" | grep -q "システム設定"'

echo "== 試しの通知: 起動しても失敗する"
tn_mode never
: >"$CALLS"
out="$("$REPO/install.sh" 2>&1)"
rc=$?
check "終了コード0で続ける" '[ "$rc" -eq 0 ] && [ -f "$PLIST" ] && grep -q "^launchctl bootstrap" "$CALLS"'
check "起動は1回だけ" '[ "$(grep -c "^open" "$CALLS")" = "1" ] && [ "$(grep -c "^terminal-notifier " "$CALLS")" = "2" ]'
check "システム設定で許可する手順を表示する" 'printf "%s" "$out" | grep -q "「システム設定」の「通知」を開く"'

echo "== 試しの通知: --dry-run では出さない"
: >"$CALLS"
"$REPO/install.sh" --dry-run >/dev/null 2>&1
check "terminal-notifier と open を呼ばない" '! grep -q "^terminal-notifier\|^open" "$CALLS"'
mv -f "$FAKEBIN/terminal-notifier" "$WORK/terminal-notifier-link.unused"

echo "== 不明な引数"
"$REPO/install.sh" --nosuch >/dev/null 2>&1
rc=$?
check "終了コード2" '[ "$rc" -eq 2 ]'

echo "== terminal-notifier も brew も無い"
rm -f "$FAKEBIN/brew"
: >"$CALLS"
out="$("$REPO/install.sh" 2>&1)"
rc=$?
check "警告して続ける" '[ "$rc" -eq 0 ] && printf "%s" "$out" | grep -q "WARN: terminal-notifier も brew もありません" && [ -f "$PLIST" ]'

echo "== local が無い版で --with-local"
NOLOCAL="$WORK/nolocal-repo"
mkdir -p "$NOLOCAL"
cp -R "$REPO/core" "$REPO/install.sh" "$NOLOCAL/"
sig="$(tree_sig)"
: >"$CALLS"
out="$("$NOLOCAL/install.sh" --with-local 2>&1)"
rc=$?
check "終了コード2" '[ "$rc" -eq 2 ]'
check "local が無いと表示する" 'printf "%s" "$out" | grep -Fq "この版には local がありません。本体だけを入れる場合は --with-local を外してください"'
check "HOME を変えず外部のコマンドを呼ばない" '[ "$(tree_sig)" = "$sig" ] && [ ! -s "$CALLS" ]'
out="$("$NOLOCAL/install.sh" --with-local --dry-run 2>&1)"
rc=$?
check "--dry-run でも終了コード2" '[ "$rc" -eq 2 ]'

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
