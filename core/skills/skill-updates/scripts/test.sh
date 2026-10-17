#!/bin/bash
# skill-updates scripts の検査。GitHub API の応答を差し替え、一時ディレクトリで動かす。ネットワークは使わない。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PYTHON="${CLAUDE_REVIEW_PYTHON:-/usr/bin/python3}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/skill-updates-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_REPORTS_ROOT="$WORK/reports"
export CLAUDE_REPORTS_STATE="$WORK/state"
export SKILL_UPDATES_LOCK="$WORK/skills-lock.json"
export SKILL_UPDATES_SKILLS_DIR="$WORK/skills"
export SKILL_UPDATES_API="$WORK/fake-api.sh"
export SKILL_UPDATES_TODAY="2026-10-18"
STATE="$CLAUDE_REPORTS_STATE/skill-updates"
API="$WORK/api"
RUN="$SCRIPT_DIR/run-if-due.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽の API。パスを英数字以外を _ にした名前のファイルを返す。無ければ失敗する。呼ばれたパスを記録する。
mkdir -p "$API" "$SKILL_UPDATES_SKILLS_DIR/sample-skill"
cat >"$SKILL_UPDATES_API" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >>"$(dirname "$0")/calls.log"
f="$(dirname "$0")/api/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
[ -n "${FAKE_API_SLEEP:-}" ] && sleep "$FAKE_API_SLEEP"
[ -f "$f" ] && cat "$f"
EOF
chmod +x "$SKILL_UPDATES_API"
api_file() { printf '%s/%s' "$API" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
COMMITS="repos/owner_a/skills/commits?path=skills%2Fsample-skill&per_page=20"
tree_path() { printf 'repos/owner_a/skills/git/trees/%s?recursive=1' "$1"; }
blob() { printf 'blob %d\0%s' "${#1}" "$1" | shasum -a 1 | cut -d' ' -f1; }

cat >"$SKILL_UPDATES_LOCK" <<'EOF'
{"version":1,"skills":{"sample-skill":{"source":"owner_a/skills","sourceType":"github","skillPath":"skills/sample-skill/SKILL.md","computedHash":"x"},"local-only":{"source":"./x","sourceType":"local"}}}
EOF
printf 'v1\n' >"$SKILL_UPDATES_SKILLS_DIR/sample-skill/SKILL.md"
printf 'meta\n' >"$SKILL_UPDATES_SKILLS_DIR/sample-skill/.hidden"

# 上流: c1（v1）。手元と同じ。
set_upstream() { # <最新のコミット> <SKILL.md の中身> <コミットの JSON の並び>
  printf '[%s]' "$3" >"$(api_file "$COMMITS")"
  printf '{"truncated":false,"tree":[{"path":"README.md","type":"blob","sha":"aaa"},{"path":"skills/sample-skill","type":"tree","sha":"t"},{"path":"skills/sample-skill/SKILL.md","type":"blob","sha":"%s"}]}' \
    "$(blob "$2")" >"$(api_file "$(tree_path "$1")")"
}
C1='{"sha":"c1","commit":{"message":"Add sample skill\n\nbody"}}'
C2='{"sha":"c2","commit":{"message":"Clarify the question order"}}'
C3='{"sha":"c3","commit":{"message":"Fix typo"}}'
set_upstream c1 $'v1\n' "$C1"

echo "== 初回: 中身が同じなら記録だけ進め、何も出さない"
out="$(bash "$RUN")"
check "出力なし" '[ -z "$out" ]'
check "記録が c1" '[ "$("$PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1]))[\"sample-skill\"][\"installed\"])" "$STATE/state.json")" = c1 ]'
check "今日の確認済みを記録" '[ "$(cat "$STATE/last-checked")" = 2026-10-18 ]'
check "結果ファイルを作らない" '[ ! -e "$CLAUDE_REPORTS_ROOT/skill-updates/2026-10-18.md" ]'
check "local の項目は確かめない" '! grep -qv "^repos/owner_a/" "$WORK/calls.log"'

echo "== 同じ日の2回目はネットワークに触れない"
: >"$WORK/calls.log"
out="$(bash "$RUN")"
check "出力なし・API を呼ばない" '[ -z "$out" ] && [ ! -s "$WORK/calls.log" ]'

echo "== 翌日、上流が c3 まで進んでいれば知らせる"
export SKILL_UPDATES_TODAY="2026-10-19"
set_upstream c3 $'v3\n' "$C3,$C2,$C1"
out="$(bash "$RUN")"
check "JSON を1つ出す" 'printf "%s" "$out" | "$PYTHON" -c "import json,sys;json.load(sys.stdin)"'
ctx="$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
sys_msg="$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys;d=json.load(sys.stdin);print(d["systemMessage"], d["hookSpecificOutput"]["hookEventName"])')"
check "additionalContext に名前と新しいコミットの件名だけ" 'printf "%s" "$ctx" | grep -Fq "sample-skill" && printf "%s" "$ctx" | grep -Fq "Fix typo、Clarify the question order" && ! printf "%s" "$ctx" | grep -Fq "Add sample skill"'
check "今対応するかを問う指示がある" 'printf "%s" "$ctx" | grep -Fq "今対応するかを利用者に問う"'
check "systemMessage と hookEventName" '[ "$sys_msg" = "外部スキルの新しい版: sample-skill SessionStart" ]'
R="$CLAUDE_REPORTS_ROOT/skill-updates/2026-10-19.md"
check "結果ファイルを書く" '[ -f "$R" ] && grep -Fq "Fix typo" "$R"'
check "記録は c1 のまま" 'grep -q "\"installed\": \"c1\"" "$STATE/state.json"'

echo "== 今はしないと答えた翌日も知らせ続ける"
export SKILL_UPDATES_TODAY="2026-10-20"
out="$(bash "$RUN")"
check "再び知らせる" 'printf "%s" "$out" | grep -Fq "sample-skill"'

echo "== mark-updated.sh で記録を進めると、翌日は知らせない"
msg="$(bash "$SCRIPT_DIR/mark-updated.sh" sample-skill)"
check "記録が c3" 'grep -q "\"installed\": \"c3\"" "$STATE/state.json" && printf "%s" "$msg" | grep -q c3'
export SKILL_UPDATES_TODAY="2026-10-21"
out="$(bash "$RUN")"
check "出力なし" '[ -z "$out" ]'
check "知らない名前は失敗" '! bash "$SCRIPT_DIR/mark-updated.sh" nosuch 2>/dev/null'

echo "== 更新した後は、中身が一致すれば記録が自動で進む"
set_upstream c4 $'v4\n' '{"sha":"c4","commit":{"message":"Add examples"}},'"$C3"
export SKILL_UPDATES_TODAY="2026-10-22"
out="$(bash "$RUN")"
check "上流 c4 を知らせる" 'printf "%s" "$out" | grep -Fq "Add examples"'
printf 'v4\n' >"$SKILL_UPDATES_SKILLS_DIR/sample-skill/SKILL.md"
export SKILL_UPDATES_TODAY="2026-10-23"
out="$(bash "$RUN")"
check "出力なし・記録が c4" '[ -z "$out" ] && grep -q "\"installed\": \"c4\"" "$STATE/state.json"'

echo "== ネットワークの失敗: 何も出さず、ログに1行、しばらく確かめ直さない"
rm -f "$(api_file "$COMMITS")"
export SKILL_UPDATES_TODAY="2026-10-24"
out="$(bash "$RUN")"
check "出力なし" '[ -z "$out" ]'
check "ログに FAIL の1行" '[ "$(grep -c FAIL "$STATE/check.log")" = 1 ]'
check "確認済みにしない" '[ "$(cat "$STATE/last-checked")" = 2026-10-23 ]'
: >"$WORK/calls.log"
bash "$RUN" >/dev/null
check "失敗の直後は API を呼ばない" '[ ! -s "$WORK/calls.log" ]'
rm -f "$STATE/last-failed"

echo "== 応答が遅ければ打ち切る"
set_upstream c4 $'v4\n' '{"sha":"c4","commit":{"message":"Add examples"}}'
start=$(date +%s)
out="$(FAKE_API_SLEEP=5 SKILL_UPDATES_DEADLINE=1 bash "$RUN")"
el=$(( $(date +%s) - start ))
check "出力なし・3秒以内に終わる（${el}秒）" '[ -z "$out" ] && [ "$el" -le 3 ]'
check "ログに打ち切りの FAIL" 'tail -n 1 "$STATE/check.log" | grep -q "FAIL: .*打ち切り"'
rm -f "$STATE/last-failed"

echo "== 別のセッションが確かめている間は何もしない"
mkdir "$STATE/lock"
: >"$WORK/calls.log"
out="$(bash "$RUN")"
check "出力なし・API を呼ばない" '[ -z "$out" ] && [ ! -s "$WORK/calls.log" ]'
rmdir "$STATE/lock"

echo "== 初回で中身が違えば、記録が無いことを添えて知らせる"
rm -f "$STATE/state.json"
printf 'local-edit\n' >"$SKILL_UPDATES_SKILLS_DIR/sample-skill/SKILL.md"
out="$(bash "$RUN")"
check "知らせる" 'printf "%s" "$out" | grep -Fq "手元の版の記録が無い"'

echo "== ロックファイルが無ければ何もしない"
rm -f "$SKILL_UPDATES_LOCK"
export SKILL_UPDATES_TODAY="2026-10-25"
: >"$WORK/calls.log"
out="$(bash "$RUN")"
check "出力なし・API を呼ばない" '[ -z "$out" ] && [ ! -s "$WORK/calls.log" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
