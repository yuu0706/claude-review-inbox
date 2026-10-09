#!/bin/bash
# tag-memory-repo.sh と backfill-memory-repo.sh の検査。HOME を一時ディレクトリに差し替え、偽のメモリと偽のリポジトリを作って実行する。
set -u
# 2つ目の設定ディレクトリの名前。利用者の環境の名前を書かないよう、中立な名前を変数で持つ。
ALT_DIR=.claude_alt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/memory-tag-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
unset MEMORY_AUDIT_TARGETS CLAUDE_REVIEW_CONFIG_DIRS XDG_CONFIG_HOME
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
HOOK="$SCRIPT_DIR/tag-memory-repo.sh"
BACKFILL="$SCRIPT_DIR/backfill-memory-repo.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽のリポジトリ。ハイフンを含む名前をサブディレクトリの下にも置く。
GIT="$HOME/Documents/git"
mkdir -p "$GIT/sample-api" "$GIT/group-a/sample-app-cms" "$GIT/group-a/sample-app" "$GIT/plain-dir" "$WORK/outside"
for r in "$GIT/sample-api" "$GIT/group-a/sample-app-cms" "$GIT/group-a/sample-app"; do
  git init -q "$r"
done

# フックへ渡す JSON を組み立てる。引数: <tool_name> <file_path> <cwd>
hook_json() {
  /usr/bin/jq -n --arg t "$1" --arg f "$2" --arg c "$3" \
    '{session_id: "test", tool_name: $t, tool_input: {file_path: $f}, cwd: $c, hook_event_name: "PostToolUse"}'
}
run_hook() {
  hook_json "$1" "$2" "$3" | "$HOOK"
}

MEM="$HOME/.claude/projects/-Users-test-proj/memory"
mkdir -p "$MEM"
BODY='本文の1行目。

- 項目: 値
末尾に改行が無い行'

# --- フック ---

f="$MEM/new.md"
printf -- '---\nname: sample-note\ndescription: 検査用\nmetadata:\n  type: project\n---\n%s' "$BODY" >"$f"
out="$(run_hook Write "$f" "$GIT/sample-api")"; rc=$?
check "フック: Write で終了コード0・出力なし" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
check "フック: Write で repo が足される" 'grep -qx "  repo: sample-api" "$f"'
check "フック: Write で repo_path が足される" 'grep -qx "  repo_path: $GIT/sample-api" "$f"'
check "フック: 2行は metadata の塊の末尾に入る" '[ "$(sed -n 5,7p "$f")" = "$(printf "  type: project\n  repo: sample-api\n  repo_path: %s" "$GIT/sample-api")" ]'
check "フック: 本文は1バイトも変わらない" '[ "$(tail -n +9 "$f"; printf x)" = "$(printf "%s" "$BODY"; printf x)" ]'

before="$(cat "$f"; printf x)"
run_hook Edit "$f" "$GIT/group-a/sample-app-cms"
check "フック: Edit で再実行しても値が変わらない" '[ "$(cat "$f"; printf x)" = "$before" ]'

f="$MEM/MEMORY.md"
printf -- '---\nmetadata:\n  type: project\n---\n- 索引\n' >"$f"
before="$(cat "$f")"
run_hook Write "$f" "$GIT/sample-api"
check "フック: MEMORY.md は変わらない" '[ "$(cat "$f")" = "$before" ]'

f="$WORK/outside/note.md"
printf -- '---\nmetadata:\n  type: project\n---\n本文\n' >"$f"
before="$(cat "$f")"
run_hook Write "$f" "$GIT/sample-api"
check "フック: memory 以外のパスは変わらない" '[ "$(cat "$f")" = "$before" ]'

f="$MEM/other-tool.md"
printf -- '---\nmetadata:\n  type: project\n---\n本文\n' >"$f"
before="$(cat "$f")"
run_hook Read "$f" "$GIT/sample-api"
check "フック: Write と Edit 以外は変わらない" '[ "$(cat "$f")" = "$before" ]'

f="$MEM/outside-cwd.md"
printf -- '---\nname: x\nmetadata: \n  type: user\n  originSessionId: abc\n---\n本文\n' >"$f"
run_hook Write "$f" "$WORK/outside"
check "フック: リポジトリ外の cwd は repo: なし" 'grep -qx "  repo: なし" "$f"'
check "フック: リポジトリ外の cwd は repo_path が cwd" 'grep -qx "  repo_path: $WORK/outside" "$f"'
check "フック: metadata の後ろに空白があっても塊の末尾に入る" '[ "$(sed -n 6p "$f")" = "  repo: なし" ] && [ "$(sed -n 8p "$f")" = "---" ]'

f="$MEM/no-metadata.md"
printf -- '---\nname: x\ndescription: y\n---\n本文\n' >"$f"
run_hook Write "$f" "$GIT/sample-api"
check "フック: metadata が無い frontmatter は metadata が足される" \
  '[ "$(cat "$f")" = "$(printf -- "---\nname: x\ndescription: y\nmetadata:\n  repo: sample-api\n  repo_path: %s\n---\n本文" "$GIT/sample-api")" ]'

f="$MEM/no-frontmatter.md"
printf '本文だけ\n---\nmetadata:\n' >"$f"
before="$(cat "$f")"
run_hook Write "$f" "$GIT/sample-api"
check "フック: frontmatter が無いファイルは変わらない" '[ "$(cat "$f")" = "$before" ]'

out="$(printf '{"tool_name": "Write", broken' | "$HOOK" 2>&1)"; rc=$?
check "フック: 壊れた JSON は終了コード0で何も出さない" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
out="$(printf '' | "$HOOK" 2>&1)"; rc=$?
check "フック: 空の入力は終了コード0で何も出さない" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
out="$(run_hook Write "$MEM/missing.md" "$GIT/sample-api" 2>&1)"; rc=$?
check "フック: 存在しないファイルは終了コード0で何も出さず作らない" '[ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$MEM/missing.md" ]'
check "フック: 一時ファイルが残らない" '[ -z "$(ls -A "$MEM" | grep "^\.memory-repo")" ]'

start=$(date +%s)
run_hook Write "$MEM/new.md" "$GIT/sample-api"
check "フック: 1秒以内に終わる" '[ $(( $(date +%s) - start )) -le 1 ]'

# --- 埋め戻し ---

rm -rf "$HOME/.claude/projects"
P1="$HOME/.claude/projects/$(printf '%s' "$GIT/group-a/sample-app-cms" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
P2="$HOME/${ALT_DIR}/projects/$(printf '%s' "$GIT/sample-api/src" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
P3="$HOME/.claude/projects/$(printf '%s' "$HOME" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
P4="$HOME/.claude/projects/$(printf '%s' "$GIT/plain-dir" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
mkdir -p "$P1" "$P2" "$P3" "$P4"
for d in "$P1" "$P2" "$P3" "$P4"; do
  printf -- '---\nname: a\nmetadata:\n  type: project\n---\n本文\n' >"$d/a.md"
  printf -- '- [a](a.md)\n' >"$d/MEMORY.md"
done
printf -- '---\nname: b\nmetadata:\n  type: project\n  repo: existing\n  repo_path: /keep\n---\n本文\n' >"$P1/b.md"

out="$("$BACKFILL")"
check "埋め戻し: 設定ディレクトリの指定が無ければ ~/.claude だけを見る" \
  'printf "%s\n" "$out" | grep -q "^$P1/a.md	" && ! printf "%s\n" "$out" | grep -q "^$HOME/${ALT_DIR}/"'
printf 'CLAUDE_REVIEW_CONFIG_DIRS=~/%s\n' "$ALT_DIR" >"$CLAUDE_REVIEW_JOBS_CONF"
out="$("$BACKFILL")"
check "埋め戻し: jobs.conf の設定ディレクトリを使う" \
  'printf "%s\n" "$out" | grep -q "^$P2/a.md	" && ! printf "%s\n" "$out" | grep -q "^$P1/a.md	"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
export CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude:~/${ALT_DIR}"

snap="$WORK/snap"
mkdir -p "$snap" && cp -Rp "$HOME/.claude" "$HOME/${ALT_DIR}" "$snap/"
out="$("$BACKFILL")"; rc=$?
check "埋め戻し: 既定は終了コード0" '[ "$rc" -eq 0 ]'
check "埋め戻し: 既定では変更しない" 'diff -r "$snap/.claude" "$HOME/.claude" >/dev/null && diff -r "$snap/${ALT_DIR}" "$HOME/${ALT_DIR}" >/dev/null'
check "埋め戻し: 既定でも一覧を出す" 'printf "%s\n" "$out" | grep -q "^$P1/a.md	sample-app-cms	"'
check "埋め戻し: 最後に件数を出す" 'printf "%s\n" "$out" | tail -n 1 | grep -q "^件数: 対象"'

out="$("$BACKFILL" --apply)"; rc=$?
check "埋め戻し: --apply は終了コード0" '[ "$rc" -eq 0 ]'
check "埋め戻し: --apply で足される" 'grep -qx "  repo: sample-app-cms" "$P1/a.md" && grep -qx "  repo_path: $GIT/group-a/sample-app-cms" "$P1/a.md"'
check "埋め戻し: ハイフンを含むサブディレクトリのリポジトリ名を正しく戻す（sample-app と取り違えない）" '! grep -q "repo: sample-app$" "$P1/a.md"'
check "埋め戻し: リポジトリの下のディレクトリはリポジトリの最上位に戻す" 'grep -qx "  repo: sample-api" "$P2/a.md" && grep -qx "  repo_path: $GIT/sample-api" "$P2/a.md"'
check "埋め戻し: ホームは repo: なし・repo_path: 不明" 'grep -qx "  repo: なし" "$P3/a.md" && grep -qx "  repo_path: 不明" "$P3/a.md"'
check "埋め戻し: git でないディレクトリは repo: なし・repo_path はそのディレクトリ" 'grep -qx "  repo: なし" "$P4/a.md" && grep -qx "  repo_path: $GIT/plain-dir" "$P4/a.md"'
check "埋め戻し: repo: がある物は飛ばす" '[ "$(cat "$P1/b.md")" = "$(printf -- "---\nname: b\nmetadata:\n  type: project\n  repo: existing\n  repo_path: /keep\n---\n本文")" ]'
check "埋め戻し: repo: がある物は一覧に出さない" '! printf "%s\n" "$out" | grep -q "^$P1/b.md"'
check "埋め戻し: MEMORY.md は変わらない" '[ "$(cat "$P1/MEMORY.md")" = "- [a](a.md)" ]'
check "埋め戻し: 本文は変わらない" '[ "$(tail -n 1 "$P1/a.md")" = "本文" ]'

out="$("$BACKFILL" --apply)"
check "埋め戻し: 2回目は足す対象が0件" 'printf "%s\n" "$out" | grep -q "足した 0件"'
"$BACKFILL" --unknown >/dev/null 2>&1; rc=$?
check "埋め戻し: 不明な引数は終了コード2" '[ "$rc" -eq 2 ]'

printf '\n結果: PASS %s件 / FAIL %s件\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
