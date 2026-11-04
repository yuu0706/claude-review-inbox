#!/bin/bash
# requires: report-inbox change-review memory-audit feedback-mining skill-audit repo-patrol secret-patrol skill-updates
# install.sh を公開版の組（tools/groups.tsv の notify・review・patrol）ごとの写しで動かし、その組のスキルの分だけを
# 入れ・外すことを確かめる。3つを同じ HOME に入れ、1つを外しても他の組のフックと定期実行が残ることも確かめる。
# 一時の HOME と偽の launchctl で動かし、本物の HOME・launchctl には触れない（2026-11-04）。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
GROUPS_FILE="$REPO/tools/groups.tsv"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-install-groups.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { if eval "$2"; then pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; else fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; fi; }

if [ ! -f "$GROUPS_FILE" ]; then
  echo "組の対応表（tools/groups.tsv）が無いため検査できません（全部入りでだけ動く）"
  exit 1
fi

# 偽のコマンド
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
export FAKE_LAUNCHD="$WORK/launchd-registered"
cat >"$FAKEBIN/launchctl" <<'EOF'
#!/bin/bash
case "$1" in
  print) [ -f "$FAKE_LAUNCHD/${2##*/}" ] ;;
  bootstrap) mkdir -p "$FAKE_LAUNCHD" && touch "$FAKE_LAUNCHD/$(plutil -extract Label raw "$3")" ;;
  bootout) rm -f "$FAKE_LAUNCHD/${2##*/}" ;;
esac
EOF
FAKE_CLT="$WORK/clt"
mkdir -p "$FAKE_CLT/usr/bin"
printf '#!/bin/bash\n' >"$FAKE_CLT/usr/bin/python3"
printf '#!/bin/bash\n[ "$1" = "-p" ] && echo "%s"\n' "$FAKE_CLT" >"$WORK/xcode-select"
printf '#!/bin/bash\nexec /usr/bin/python3 "$@"\n' >"$WORK/python3"
printf '#!/bin/bash\nexit 0\n' >"$FAKEBIN/claude"
chmod +x "$FAKEBIN/launchctl" "$FAKE_CLT/usr/bin/python3" "$WORK/xcode-select" "$WORK/python3" "$FAKEBIN/claude"
export CLAUDE_REVIEW_XCODE_SELECT="$WORK/xcode-select"
export CLAUDE_REVIEW_SYSTEM_PYTHON="$WORK/python3"
export CLAUDE_REVIEW_CLAUDE_PATHS=""
export PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin"
unset CLAUDE_REVIEW_PYTHON XDG_CONFIG_HOME CLAUDE_REVIEW_CONFIG_DIRS CLAUDE_REVIEW_JOBS_CONF CLAUDE_REVIEW_CHANGES_LOG

# 組ごとの写し（書き出しと同じく、その組のスキルだけを持つ）
make_copy() {
  local g="$1" d="$WORK/repo-$1" s
  mkdir -p "$d/core/skills"
  cp "$REPO/install.sh" "$d/install.sh"
  for s in $(awk -F '\t' -v g="$g" '$1 == g { print $2; exit }' "$GROUPS_FILE"); do
    cp -R "$REPO/core/skills/$s" "$d/core/skills/"
  done
  printf '%s\n' "$d"
}
NOTIFY="$(make_copy notify)"
REVIEW="$(make_copy review)"
PATROL="$(make_copy patrol)"

new_home() {
  export HOME="$WORK/home-$1"
  rm -rf "$HOME"
  mkdir -p "$HOME/.claude/skills"
  printf '{}\n' >"$HOME/.claude/settings.json"
  rm -rf "$FAKE_LAUNCHD"
}
hooks() { /usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(sorted(x["command"].split("/core/skills/")[-1] for e in d.get("hooks", {}).get("SessionStart", []) for x in e.get("hooks", []))))' "$HOME/.claude/settings.json"; }
links() { ls "$HOME/.claude/skills" | tr '\n' ' ' | sed 's/ $//'; }
jobs() { [ -d "$FAKE_LAUNCHD" ] && ls "$FAKE_LAUNCHD" | sed 's/^com\.[^.]*\.//' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
CONF_REL=".config/claude-review-inbox/patrol.conf"

echo "== 知らせの組"
new_home notify
out="$("$NOTIFY/install.sh" --yes </dev/null 2>&1)"; rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "report-inbox だけを置く" '[ "$(links)" = "report-inbox" ]'
check "フックは unread.sh だけ" '[ "$(hooks)" = "report-inbox/scripts/unread.sh" ]'
check "定期実行を登録しない" '[ -z "$(jobs)" ]'
check "見回りの範囲を書かない" '[ ! -e "$HOME/$CONF_REL" ]'
check "記録の置き場所を作らない" '[ ! -e "$HOME/.local/state/claude-reports/changes" ] && [ ! -e "$HOME/claude-reports/proposals" ]'
check "週1回の見直しを聞かない・claude の行を出さない" '! printf "%s" "$out" | grep -q "週1回の見直し"'

echo "== 見直しの組"
new_home review
out="$("$REVIEW/install.sh" --yes --with-schedule </dev/null 2>&1)"; rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "見直しの4つだけを置く" '[ "$(links)" = "change-review feedback-mining memory-audit skill-audit" ]'
check "フックを足さない" '[ -z "$(hooks)" ]'
check "週1回の見直しの3つを登録する" '[ "$(jobs)" = "feedback-mining memory-audit skill-audit" ]'
check "見回りの範囲を書かない" '[ ! -e "$HOME/$CONF_REL" ]'
check "記録の置き場所を作る" '[ -d "$HOME/.local/state/claude-reports/changes" ] && [ -d "$HOME/claude-reports/proposals" ]'
check "知らせの組を案内する" 'printf "%s" "$out" | grep -q "claude-report-inbox も入れます"'

echo "== 見回りの組"
new_home patrol
out="$("$PATROL/install.sh" --yes --with-schedule </dev/null 2>&1)"; rc=$?
check "終了コード0" '[ "$rc" -eq 0 ]'
check "見回りの3つだけを置く" '[ "$(links)" = "repo-patrol secret-patrol skill-updates" ]'
check "フックは見回りの3つ" '[ "$(hooks)" = "repo-patrol/scripts/run-if-due.sh secret-patrol/scripts/session-trigger.sh skill-updates/scripts/run-if-due.sh" ]'
check "--with-schedule でも定期実行を登録しない" '[ -z "$(jobs)" ]'
check "見回りの範囲を書く" '[ -f "$HOME/$CONF_REL" ]'

echo "== 3つを同じ HOME に入れて、1つずつ外す"
new_home all
for r in "$NOTIFY" "$REVIEW" "$PATROL"; do "$r/install.sh" --yes --with-schedule </dev/null >/dev/null 2>&1; done
check "8つのスキルを置く" '[ "$(links | wc -w | tr -d " ")" = 8 ]'
check "4つのフックを足す" '[ "$(hooks | wc -w | tr -d " ")" = 4 ]'
check "定期実行は3つ" '[ "$(jobs)" = "feedback-mining memory-audit skill-audit" ]'
"$PATROL/install.sh" --uninstall </dev/null >/dev/null 2>&1; rc=$?
check "見回りを外す: 終了コード0" '[ "$rc" -eq 0 ]'
check "見回りを外す: 他の組のスキルは残る" '[ "$(links)" = "change-review feedback-mining memory-audit report-inbox skill-audit" ]'
check "見回りを外す: 知らせのフックは残る" '[ "$(hooks)" = "report-inbox/scripts/unread.sh" ]'
check "見回りを外す: 見直しの定期実行は残る" '[ "$(jobs)" = "feedback-mining memory-audit skill-audit" ]'
"$NOTIFY/install.sh" --uninstall </dev/null >/dev/null 2>&1
check "知らせを外す: 見直しの定期実行は残る" '[ "$(jobs)" = "feedback-mining memory-audit skill-audit" ] && [ -z "$(hooks)" ]'
"$REVIEW/install.sh" --uninstall </dev/null >/dev/null 2>&1
check "見直しを外す: すべて消える" '[ -z "$(links)" ] && [ -z "$(hooks)" ] && [ -z "$(jobs)" ]'

printf '\nRESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
