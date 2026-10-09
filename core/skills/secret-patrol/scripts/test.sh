#!/bin/bash
# secret-patrol scripts の検査。一時ディレクトリに偽の利用者の環境と偽の gitleaks を作って実行する。
# 実際の ~/Documents・~/Downloads・~/.claude は読まない。ネットワークは使わない。
set -u
# 2つ目の設定ディレクトリの名前。利用者の環境の名前を書かないよう、中立な名前を変数で持つ。
ALT_DIR=.claude_alt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/secret-patrol-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

H="$WORK/home"
export SECRET_PATROL_HOME="$H"
export CLAUDE_REPORTS_ROOT="$WORK/reports"
export CLAUDE_REPORTS_STATE="$WORK/state"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export FAKE_GITLEAKS_LOG="$WORK/gitleaks-args.log"
export FAKE_GITLEAKS_CONFIGS="$WORK/configs"
# 見回りの範囲の設定ファイル。書類・デスクトップ・ダウンロードと2つのリポジトリの置き場所を見回る。
export CLAUDE_REVIEW_PATROL_CONF="$WORK/patrol.conf"
printf 'PERSONAL_FOLDERS=yes\nREPO_ROOTS=%s\n' "$H/Documents/git:$H/dev" >"$CLAUDE_REVIEW_PATROL_CONF"
# 設定ディレクトリを2つ持つ形にし、スキルの除外とフックの判定の文字列を与える。共通の設定ファイルは一時の場所を指す。
unset XDG_CONFIG_HOME
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
export CLAUDE_REVIEW_CONFIG_DIRS="$H/.claude:$H/${ALT_DIR}"
export SECRET_PATROL_SKILL_EXCLUDES="synced"
export SECRET_PATROL_HOOK_PATTERN="hooks/secret-scan.sh"
STATE="$CLAUDE_REPORTS_STATE/secret-patrol"
BASE="$STATE/baseline"
OUT="$CLAUDE_REPORTS_ROOT/secret-patrol"
mkdir -p "$FAKE_GITLEAKS_CONFIGS"

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

# ---- 偽の gitleaks ----
# FAKESECRET_ で始まる文字列を秘密として扱う。dir と git のサブコマンド、--config の allowlist の paths、
# --baseline-path、--redact、--follow-symlinks を真似る。受け取った引数を FAKE_GITLEAKS_LOG に残す。
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gitleaks" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_GITLEAKS_LOG"
sub="$1"; shift
report=""; base=""; cfg=""; redact=0; logopts=""; target=""; follow=""
while [ $# -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift ;;
    --baseline-path) base="$2"; shift ;;
    --config) cfg="$2"; shift ;;
    --report-format|--exit-code) shift ;;
    --redact) redact=1 ;;
    --follow-symlinks) follow="-L" ;;
    --log-opts=*) logopts="${1#--log-opts=}" ;;
    --*) ;;
    *) target="$1" ;;
  esac
  shift
done
[ -n "$cfg" ] && cp "$cfg" "$FAKE_GITLEAKS_CONFIGS/$(date +%s)-$RANDOM.toml"
# 本物の gitleaks 8.30 は、空の allowlist を含む設定を読み込めず終了コード 1 で終わる。同じ振る舞いをする。
if [ -n "$cfg" ] && grep -q '^\[allowlist\]' "$cfg" && ! grep -q "^  '''" "$cfg"; then
  echo 'FTL Failed to load config error="[[allowlists]] must contain at least one check"' >&2
  exit 1
fi
excl="$(mktemp)"
[ -n "$cfg" ] && sed -n "s/^  '''\(.*\)''',\$/\1/p" "$cfg" >"$excl"
n=0
emit() {
  local file="$1" line="$2" secret="$3" commit="$4" fp shown
  fp="${commit:+$commit:}$file:fake-rule:$line"
  if [ -n "$base" ] && grep -Fq "\"Fingerprint\": \"$fp\"" "$base"; then return; fi
  shown="$secret"; [ "$redact" -eq 1 ] && shown="REDACTED"
  [ "$n" -gt 0 ] && printf ',\n'
  printf '{"Description": "fake", "StartLine": %s, "EndLine": %s, "Match": "token = %s", "Secret": "%s", "File": "%s", "Commit": "%s", "RuleID": "fake-rule", "Fingerprint": "%s"}' \
    "$line" "$line" "$shown" "$shown" "$file" "$commit" "$fp"
  n=$((n + 1))
}
{
  printf '[\n'
  if [ "$sub" = "dir" ]; then
    while IFS= read -r f; do
      if [ -s "$excl" ] && printf '%s\n' "$f" | grep -Eqf "$excl"; then continue; fi
      while IFS=: read -r line secret; do
        [ -n "$secret" ] && emit "$f" "$line" "$secret" ""
      done <<EOT
$(grep -n -o 'FAKESECRET_[A-Za-z0-9]*' "$f" 2>/dev/null)
EOT
    done <<EOT
$(find $follow "$target" -type f)
EOT
  else
    # shellcheck disable=SC2086
    for c in $(git -C "$target" rev-list $logopts); do
      for f in $(git -C "$target" diff-tree --root --no-commit-id --name-only -r "$c"); do
        while IFS=: read -r line secret; do
          [ -n "$secret" ] && emit "$f" "$line" "$secret" "$c"
        done <<EOT
$(git -C "$target" show "$c:$f" 2>/dev/null | grep -n -o 'FAKESECRET_[A-Za-z0-9]*')
EOT
      done
    done
  fi
  printf '\n]\n'
} >"$report"
rm -f "$excl"
exit 0
EOF
chmod +x "$WORK/bin/gitleaks"
export PATH="$WORK/bin:$PATH"

# ---- 偽の利用者の環境 ----
q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
mkdir -p "$H/.claude/projects/p1/memory" "$H/${ALT_DIR}/skills/s1/history" "$H/${ALT_DIR}/skills/synced/x" \
  "$H/${ALT_DIR}/skills/.hidden" "$H/${ALT_DIR}/rules" "$H/Downloads" "$H/Desktop" "$H/Documents/git/group-a" "$H/dev"
echo "token FAKESECRET_mem1" >"$H/.claude/projects/p1/memory/note.md"
printf 'line\nkey FAKESECRET_skill1\n' >"$H/${ALT_DIR}/skills/s1/SKILL.md"
echo "FAKESECRET_hist" >"$H/${ALT_DIR}/skills/s1/history/old.md"
echo "FAKESECRET_synced" >"$H/${ALT_DIR}/skills/synced/x/SKILL.md"
echo "FAKESECRET_hidden" >"$H/${ALT_DIR}/skills/.hidden/a.md"
echo "# rules" >"$H/${ALT_DIR}/CLAUDE.md"
cat >"$H/.claude/settings.json" <<'EOF'
{"permissions": {"deny": ["Read(//**/.env)", "Read(//**/.env.*)", "Read(~/.aws/credentials)", "Read(~/.ssh/**)", "Read(//**/*.pem)", "Read(//**/*.key)"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/hooks/secret-scan.sh"}]}]}}
EOF
cat >"$H/${ALT_DIR}/settings.json" <<'EOF'
{"permissions": {"deny": ["Read(//**/.env)", "Read(**/*.pem)", "Read(~/.ssh/**)", "Read(//**/*.key)"]}, "hooks": {}}
EOF

# repo1: 上流あり。作業ツリーの秘密、node_modules の秘密（除外）、push していないコミットの秘密。
git init -q --bare "$WORK/remote/origin.git"
git init -q "$WORK/seed"
echo "seed" >"$WORK/seed/readme.txt"; q "$WORK/seed" add .; q "$WORK/seed" commit -m "初期"
q "$WORK/seed" push "$WORK/remote/origin.git" main
git clone -q "$WORK/remote/origin.git" "$H/Documents/git/repo1"
echo "FAKESECRET_tree1" >"$H/Documents/git/repo1/config.txt"
mkdir -p "$H/Documents/git/repo1/node_modules/pkg" "$H/Documents/git/repo1/dist"
echo "FAKESECRET_nm" >"$H/Documents/git/repo1/node_modules/pkg/index.js"
echo "FAKESECRET_dist" >"$H/Documents/git/repo1/dist/out.js"
echo "FAKESECRET_commit1" >"$H/Documents/git/repo1/added.txt"
q "$H/Documents/git/repo1" add added.txt; q "$H/Documents/git/repo1" commit -m "追加"
# .gitignore に書いたファイル、入れ子のリポジトリ、リポジトリの外を指すリンクは作業ツリーの見回りで見ない。
printf 'ignored.log\nlog/\n' >"$H/Documents/git/repo1/.gitignore"
echo "FAKESECRET_ignored" >"$H/Documents/git/repo1/ignored.log"
mkdir -p "$H/Documents/git/repo1/log"; echo "FAKESECRET_logdir" >"$H/Documents/git/repo1/log/app.txt"
git init -q "$H/Documents/git/repo1/repos/inner"
echo "FAKESECRET_nested" >"$H/Documents/git/repo1/repos/inner/x.txt"
mkdir -p "$WORK/outside"; echo "FAKESECRET_outside" >"$WORK/outside/s.txt"
ln -s "$WORK/outside/s.txt" "$H/Documents/git/repo1/link.txt"
# repo2: まとめフォルダの中。上流なし。
git init -q "$H/Documents/git/group-a/repo2"
echo "FAKESECRET_r2" >"$H/Documents/git/group-a/repo2/app.txt"
q "$H/Documents/git/group-a/repo2" add .; q "$H/Documents/git/group-a/repo2" commit -m "初期"
# repo3: ~/dev の下。push 済みで秘密なし。個人情報らしき CSV を持つ。node_modules の CSV は除く。
git clone -q "$WORK/remote/origin.git" "$H/dev/repo3"
mkdir -p "$H/dev/repo3/node_modules/x"
: >"$H/dev/repo3/list.csv"; : >"$H/dev/repo3/node_modules/x/list.csv"
# 深さ3は対象外。
mkdir -p "$H/dev/a/b"; git init -q "$H/dev/a/b/deep"; echo "FAKESECRET_deep" >"$H/dev/a/b/deep/x.txt"

# 個人情報の候補。値は中立なダミーである。
: >"$H/Downloads/users.tsv"; : >"$H/Downloads/examples.csv"; : >"$H/Desktop/few.txt"; : >"$H/Downloads/image.png"
for i in $(seq -w 1 25); do
  printf 'test_user_%s\tuser%s@example.jp\n' "$i" "$i" >>"$H/Downloads/users.tsv"
  printf 'user%s@example.jp\n' "$i" >>"$H/dev/repo3/list.csv"
  printf 'user%s@example.jp\n' "$i" >>"$H/dev/repo3/node_modules/x/list.csv"
  printf 'user%s@example.com,user%s@mail.example.org\n' "$i" "$i" >>"$H/Downloads/examples.csv"
done
printf 'header\n' >>"$H/Downloads/users.tsv"
for i in 1 2 3 4 5; do printf 'user%s@example.jp\n' "$i" >>"$H/Desktop/few.txt"; done
for i in $(seq 1 30); do printf 'user%s@example.jp\n' "$i" >>"$H/Downloads/image.png"; done
mkdir -p "$H/Documents/git/repo1/node_modules/y"
cp "$H/dev/repo3/list.csv" "$H/Documents/git/repo1/node_modules/y/list.csv"

snapshot() {
  (cd "$H" && find . -path ./Downloads/locked -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(md5 -q "$f")" "$f"
  done)
  for r in "$H/Documents/git/repo1" "$H/Documents/git/group-a/repo2" "$H/dev/repo3"; do
    git -C "$r" status --porcelain; git -C "$r" for-each-ref
  done
}
before="$(snapshot)"

echo "== ネットワークと書き込みに関わるコマンドを使っていない"
check "curl/wget/nc/fetch/pull/push/clone を含まない" \
  '! grep -v "^ *#" "$SCRIPT_DIR/patrol.sh" | grep -Ev "^ *printf " | grep -Eq "(^|[^a-zA-Z_-])(curl|wget|nc|fetch|pull|push|clone)( |$)"'
check "brew と launchctl を呼ばない" '! grep -Eq "(brew|launchctl) " "$SCRIPT_DIR/patrol.sh" "$SCRIPT_DIR/session-trigger.sh"'

echo "== 初回の実行"
"$SCRIPT_DIR/patrol.sh"
rc=$?
day="$(date '+%Y-%m-%d')"
rep="$OUT/$day.md"
check "終了コード0" '[ "$rc" -eq 0 ]'
check "レポートが作られる" '[ -f "$rep" ]'
cat "$rep"
has() { grep -Fq -- "$1" "$rep"; }
section() { awk -v h="## $1" '$0==h{f=1;next} /^## /{f=0} f' "$rep"; }
new="$(section "新規の秘密")"
check "a: メモリの秘密が新規" 'printf "%s" "$new" | grep -Fq "| a | ~/.claude/projects/p1/memory/note.md:1 | fake-rule | - |"'
check "a: スキルの秘密が新規" 'printf "%s" "$new" | grep -Fq "| a | ~/${ALT_DIR}/skills/s1/SKILL.md:2 | fake-rule | - |"'
check "a: synced・. で始まるディレクトリ・history は除く" \
  '! printf "%s" "$new" | grep -Eq "synced|\.hidden|history"'
check "b: 作業ツリーの秘密が新規" 'printf "%s" "$new" | grep -Fq "| b（作業ツリー） | ~/Documents/git/repo1/config.txt:1 |"'
check "b: node_modules と dist は除く" '! printf "%s" "$new" | grep -Eq "node_modules|dist/"'
check "b: 追跡していないが無視もされていないファイルの秘密は出る（config.txt は未追跡）" \
  '[ -n "$(git -C "$H/Documents/git/repo1" ls-files -o --exclude-standard config.txt)" ] && printf "%s" "$new" | grep -Fq "~/Documents/git/repo1/config.txt:1"'
check "b: .gitignore に書いたファイルの秘密は出ない" '! printf "%s" "$new" | grep -Eq "ignored\.log|/log/app\.txt"'
check "b: 入れ子のリポジトリの秘密は親の b に出ない" '! printf "%s" "$new" | grep -Fq "repos/inner"'
check "b: シンボリックリンクは辿らない" '! printf "%s" "$new" | grep -Fq "link.txt"'
check "b: 結果のパスに一時ディレクトリのパスが出ない" '! printf "%s" "$new" | grep -Fq "$WORK" && ! has "/tree/"'
check "b: リンクを並べたディレクトリが残らない" '[ ! -e "$STATE/tree" ]'
check "b: 作業ツリーは --follow-symlinks でリンクの並びを調べる" 'grep -q "^dir --follow-symlinks .*$STATE/tree" "$FAKE_GITLEAKS_LOG"'
bt_first="$(printf "%s\n" "$new" | grep -c "^| b（作業ツリー） ")"
c1="$(git -C "$H/Documents/git/repo1" rev-parse --short=7 HEAD)"
check "b: 未push のコミットの秘密がコミット付きで新規" \
  'printf "%s" "$new" | grep -Fq "| b（未push） | ~/Documents/git/repo1/added.txt:1 | fake-rule | $c1 |"'
check "b: 上流の無いまとめフォルダの中のリポジトリも見る" \
  'printf "%s" "$new" | grep -Fq "| b（未push） | ~/Documents/git/group-a/repo2/app.txt:1 |"'
check "b: push 済みの初期コミットは見ない" '! printf "%s" "$new" | grep "未push" | grep -Fq "readme.txt"'
check "b: 深さ3のリポジトリは見ない" '! has "deep"'
check "上流ありは @{u}..HEAD、上流なしは --branches --not --remotes で調べる" \
  'grep -Fq -- "--log-opts=@{u}..HEAD" "$FAKE_GITLEAKS_LOG" && grep -Fq -- "--log-opts=--branches --not --remotes" "$FAKE_GITLEAKS_LOG"'
check "gitleaks の呼び出しはすべて --redact 付き" '! grep -v -- "--redact" "$FAKE_GITLEAKS_LOG" | grep -q .'
check "設定ファイルは既定のルールを残す" 'grep -lq "useDefault = true" "$FAKE_GITLEAKS_CONFIGS"/*.toml'
check "結果に値を書かない" '! has "FAKESECRET_" && ! has "REDACTED"'
pii="$(section "個人情報の置き忘れの候補")"
check "c: Downloads の TSV が候補（行数 26 / 該当 25）" \
  'printf "%s" "$pii" | grep -Eq "^\| ~/Downloads/users.tsv \| 26 \| 25 \| [0-9]{4}-[0-9]{2}-[0-9]{2} \|$"'
check "c: ~/dev のリポジトリの CSV が候補" 'printf "%s" "$pii" | grep -Fq "| ~/dev/repo3/list.csv | 25 | 25 |"'
check "c: example ドメインだけのファイルは候補にしない" '! printf "%s" "$pii" | grep -Fq "examples.csv"'
check "c: 20行未満は候補にしない" '! printf "%s" "$pii" | grep -Fq "few.txt"'
check "c: 対象外の拡張子は候補にしない" '! printf "%s" "$pii" | grep -Fq "image.png"'
check "c: node_modules の中は候補にしない" '! printf "%s" "$pii" | grep -Fq "node_modules"'
check "c: 中身を書かない" '! has "example.jp" &&! has "test_user_"'
grd="$(section "守りの設定")"
check "d: ~/.claude/settings.json は 6つ中6つ・hook あり" \
  'printf "%s" "$grd" | grep -Fq "| ~/.claude/settings.json | 6つ中6つ | あり |"'
check "d: 混在の ~/${ALT_DIR}/settings.json は 6つ中3つ・古い書き方を未設定と分けて書く・hook なし（未設定）" \
  'printf "%s" "$grd" | grep "~/${ALT_DIR}/settings.json" | grep -Fq "6つ中3つ（未設定: Read(//**/.env.*)、Read(~/.aws/credentials)、書き方が古い（作業場所の外を止めない）: Read(**/*.pem)）" &&printf "%s" "$grd" | grep "~/${ALT_DIR}/settings.json" | grep -Fq "なし（未設定）"'
check "読めなかった対象は該当なし" '[ "$(section "読めなかった対象" | grep -v "^$")" = "該当なし" ]'
check "既知は該当なし（初回）" '[ "$(section "既知" | grep -v "^$")" = "該当なし" ]'
check "baseline が保存される" '[ -n "$(ls "$BASE"/a-*.json "$BASE"/bt-tree-*.json "$BASE"/bg-git-*.json 2>/dev/null)" ]'
check "baseline に値が入らない（REDACTED になっている）" \
  '! grep -rq "FAKESECRET_" "$BASE" && grep -rq "REDACTED" "$BASE"'
check "ログに値が入らない" '! grep -rq "FAKESECRET_\|example\.jp" "$STATE/logs"'
check "lock が解放されている" '[ ! -d "$STATE/lock" ]'
check "一時ファイルが残らない" '[ -z "$(ls -d "${TMPDIR:-/tmp}"/secret-patrol.* 2>/dev/null)" ]'

echo "== 2回目は既知だけ（連番）"
"$SCRIPT_DIR/patrol.sh"
rc=$?
rep="$OUT/$day-2.md"
check "終了コード0" '[ "$rc" -eq 0 ]'
check "2回目は ${day}-2.md" '[ -f "$rep" ]'
check "新規は該当なし" '[ "$(section "新規の秘密" | grep -v "^$")" = "該当なし" ]'
check "既知に a の 2件" 'section "既知" | grep -Fxq -- "- a. Claude 自身の記録: 2件"'
check "既知に未push の 2件" 'section "既知" | grep -Fxq -- "- b. push していないコミット: 2件"'
check "既知の作業ツリーは1回目の新規と同じ ${bt_first}件（指紋が実行ごとに変わらない）" \
  '[ "$bt_first" -gt 0 ] && section "既知" | grep -Fxq -- "- b. リポジトリの作業ツリー: ${bt_first}件"'
check "件数の表に新規 0・既知 2（a）" 'has "| a. Claude 自身の記録 | 0 | 2 |"'

echo "== 新しい秘密だけが新規に出て、baseline が置き換わる"
echo "FAKESECRET_mem2" >>"$H/.claude/projects/p1/memory/note.md"
"$SCRIPT_DIR/patrol.sh"
rep="$OUT/$day-3.md"
new="$(section "新規の秘密")"
check "新規は1件だけ" '[ "$(printf "%s\n" "$new" | grep -c "^| a ")" = "1" ] && printf "%s" "$new" | grep -Fq "note.md:2"'
"$SCRIPT_DIR/patrol.sh"
rep="$OUT/$day-4.md"
check "次の回は新規なし・既知 3件" \
  '[ "$(section "新規の秘密" | grep -v "^$")" = "該当なし" ] && section "既知" | grep -Fxq -- "- a. Claude 自身の記録: 3件"'

echo "== --stdout は baseline を変えない"
bl_before="$(cd "$BASE" && ls -l)"
echo "FAKESECRET_mem3" >>"$H/.claude/projects/p1/memory/note.md"
out="$("$SCRIPT_DIR/patrol.sh" --stdout)"
check "--stdout は標準出力へ出す" 'printf "%s" "$out" | grep -Fq "# 秘密情報と個人情報の見回りレポート"'
check "--stdout でも値を出さない" '! printf "%s" "$out" | grep -Fq "FAKESECRET_"'
check "baseline が変わらない" '[ "$bl_before" = "$(cd "$BASE" && ls -l)" ]'
check "新しいレポートを作らない" '[ ! -f "$OUT/$day-5.md" ]'

echo "== --reset-baseline"
"$SCRIPT_DIR/patrol.sh" --reset-baseline
rep="$OUT/$day-5.md"
check "baseline を消してから走るので全件が新規" \
  '[ "$(section "新規の秘密" | grep -c "^| a ")" = "4" ] && [ "$(section "既知" | grep -v "^$")" = "該当なし" ]'

echo "== gitleaks が無い"
SECRET_PATROL_GITLEAKS="gitleaks-not-installed-$$" "$SCRIPT_DIR/patrol.sh"
rc=$?
rep="$OUT/$day-6.md"
check "終了コード1" '[ "$rc" -eq 1 ]'
check "結果は書く（c と d を含む）" '[ -f "$rep" ] && has "~/Downloads/users.tsv" && has "6つ中6つ"'
check "件数の表に調べていない旨を書く" 'has "gitleaks が無いため調べていない"'
lastlog="$(ls "$STATE/logs/"*.log | tail -1)"
check "ログに report-inbox が拾う形の ERROR の行がある" \
  'grep -Eq "^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] ERROR: gitleaks が見つかりません" "$lastlog"'

echo "== 読めなかった対象"
mkdir -p "$H/Downloads/locked"; echo x >"$H/Downloads/locked/a.csv"; chmod 000 "$H/Downloads/locked"
mkdir -p "$H/dev/repo3/secret-dir"; echo "FAKESECRET_x" >"$H/dev/repo3/secret-dir/a.txt"; chmod 000 "$H/dev/repo3/secret-dir"
"$SCRIPT_DIR/patrol.sh"
rc=$?
rep="$OUT/$day-7.md"
chmod 755 "$H/Downloads/locked" "$H/dev/repo3/secret-dir"
rm -rf "$H/Downloads/locked" "$H/dev/repo3/secret-dir"
ur="$(section "読めなかった対象")"
check "終了コード1" '[ "$rc" -eq 1 ]'
check "find で読めなかったディレクトリをパスと理由付きで書く" \
  'printf "%s" "$ur" | grep -Fq "| ~/Downloads/locked | Permission denied |"'
check "gitleaks が一部を読めなかった対象を書く" 'printf "%s" "$ur" | grep -Fq "| ~/dev/repo3 | Permission denied（一部のファイル） |"'
check "ほかの区分は続けて調べる" 'has "~/Downloads/users.tsv" && has "6つ中6つ"'
lastlog="$(ls "$STATE/logs/"*.log | tail -1)"
check "ログに ERROR の行がある" 'grep -Eq "^\[[^]]+\] ERROR: 読めなかった対象: ~/Downloads/locked" "$lastlog"'

echo "== settings.json が無い・壊れている"
mv "$H/${ALT_DIR}/settings.json" "$WORK/settings.bak"
out="$("$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
rc=$?
check "無い場合は失敗にしない" '[ "$rc" -eq 0 ] && printf "%s" "$out" | grep -Fq "| ~/${ALT_DIR}/settings.json | ファイルが存在しません | - |"'
echo "{ broken" >"$H/${ALT_DIR}/settings.json"
out="$("$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
rc=$?
check "壊れている場合は読めなかった対象として失敗にする" \
  '[ "$rc" -eq 1 ] && printf "%s" "$out" | grep -Fq "| ~/${ALT_DIR}/settings.json | JSON として解析できませんでした |"'
cat >"$H/${ALT_DIR}/settings.json" <<'EOF'
{"permissions": {"deny": ["Read(**/.env)", "Read(**/.env.*)", "Read(~/.aws/credentials)", "Read(~/.ssh/**)", "Read(**/*.pem)", "Read(**/*.key)"]}}
EOF
out="$("$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
rc=$?
check "d: 古い書き方だけの場合は設定済みに数えず「書き方が古い」と書く（失敗にはしない）" \
  '[ "$rc" -eq 0 ] && printf "%s" "$out" | grep "~/${ALT_DIR}/settings.json" | grep -Fq "6つ中2つ（書き方が古い（作業場所の外を止めない）: Read(**/.env)、Read(**/.env.*)、Read(**/*.pem)、Read(**/*.key)）"'
check "d: 古い書き方だけの場合に「未設定」とは書かない" '! printf "%s" "$out" | grep "~/${ALT_DIR}/settings.json" | grep -Fq "未設定:"'
mv "$WORK/settings.bak" "$H/${ALT_DIR}/settings.json"
# 下の比較のため、追記した秘密を初期の状態へ戻す。
echo "token FAKESECRET_mem1" >"$H/.claude/projects/p1/memory/note.md"

echo "== 対象のファイルを書き換えない"
after="$(snapshot)"
check "ファイルの中身と git の状態が変わらない" '[ "$before" = "$after" ]'

echo "== 設定ディレクトリ・スキルの除外・フックの判定の指定"
out="$(env -u CLAUDE_REVIEW_CONFIG_DIRS "$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "指定が無ければ ~/.claude だけを見る" '! printf "%s" "$out" | grep -Fq "${ALT_DIR}" && printf "%s" "$out" | grep -Fq "| ~/.claude/settings.json |"'
out="$(env -u SECRET_PATROL_HOOK_PATTERN "$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "フックの判定の文字列が無ければ確かめない" 'printf "%s" "$out" | grep "~/.claude/settings.json" | grep -Fq "確かめていない（SECRET_PATROL_HOOK_PATTERN が未設定）"'
out="$(env -u SECRET_PATROL_SKILL_EXCLUDES "$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "スキルの除外が無ければ名前では除かない" 'printf "%s" "$out" | grep -Fq "~/${ALT_DIR}/skills/synced/x/SKILL.md"'
printf 'CLAUDE_REVIEW_CONFIG_DIRS=%s\nSECRET_PATROL_HOOK_PATTERN=hooks/other.sh\n' "$H/.claude" >"$CLAUDE_REVIEW_JOBS_CONF"
out="$(env -u CLAUDE_REVIEW_CONFIG_DIRS -u SECRET_PATROL_HOOK_PATTERN "$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "共通の設定ファイルの値を使う" '! printf "%s" "$out" | grep -Fq "${ALT_DIR}" && printf "%s" "$out" | grep "~/.claude/settings.json" | grep -Fq "なし（未設定）"'
rm -f "$CLAUDE_REVIEW_JOBS_CONF"
ln -s "$H/${ALT_DIR}/skills" "$H/.claude/skills"
out="$("$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "リンクで同じ実体を指すスキルの置き場所は1回だけ見る" '[ "$(printf "%s\n" "$out" | grep -c "s1/SKILL.md:2")" = "1" ]'
rm -f "$H/.claude/skills"

echo "== 二重起動の拒否"
mkdir "$STATE/lock"
"$SCRIPT_DIR/patrol.sh" --stdout >/dev/null 2>&1
rc=$?
check "lock があれば終了コード1" '[ "$rc" -eq 1 ]'
check "他者の lock を消さない" '[ -d "$STATE/lock" ]'
rmdir "$STATE/lock"

echo "== 不明な引数"
"$SCRIPT_DIR/patrol.sh" --unknown >/dev/null 2>&1
rc=$?
check "終了コード2" '[ "$rc" -eq 2 ]'

echo "== ログの保持件数"
for i in $(seq 1 40); do touch -t "200001010000.$(printf '%02d' $((i % 60)))" "$STATE/logs/old-$i.log"; done
"$SCRIPT_DIR/patrol.sh"
n="$(ls "$STATE/logs/"*.log | wc -l | tr -d ' ')"
check "ログは30件以下（実際: ${n}）" '[ "$n" -le 30 ]'

echo "== SessionStart フックからの起動（session-trigger.sh）"
# 偽の patrol.sh は、起動されたことを印のファイルに書くだけである。
TRIG="$SCRIPT_DIR/session-trigger.sh"
TS="$WORK/trigger-state"
TSTATE="$TS/secret-patrol"
MARK="$WORK/trigger-mark"
cat >"$WORK/fake-patrol.sh" <<'EOF'
#!/bin/bash
printf 'started\n' >>"$TRIGGER_MARK"
EOF
cat >"$WORK/slow-patrol.sh" <<'EOF'
#!/bin/bash
sleep 5
printf 'started\n' >>"$TRIGGER_MARK"
EOF
export TRIGGER_MARK="$MARK"
# 引数: 間隔の日数（空なら既定） 起動するスクリプト 状態の置き場所。フックの JSON を標準入力に渡す。
run_trigger() {
  rm -f "$MARK"
  if [ -n "$1" ]; then
    printf '{"hook_event_name": "SessionStart"}\n' | SECRET_PATROL_INTERVAL_DAYS="$1" SECRET_PATROL_SCRIPT="$2" CLAUDE_REPORTS_STATE="$3" /bin/bash "$TRIG" >"$WORK/trigger.out"
  else
    printf '{"hook_event_name": "SessionStart"}\n' | env -u SECRET_PATROL_INTERVAL_DAYS SECRET_PATROL_SCRIPT="$2" CLAUDE_REPORTS_STATE="$3" /bin/bash "$TRIG" >"$WORK/trigger.out"
  fi
  T_RC=$?
}
# 印が書かれるのを最大 3 秒待つ。
wait_mark() {
  local i=0
  while [ ! -s "$MARK" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$MARK" ]
}
now="$(date +%s)"

rm -rf "$TS"
run_trigger "" "$WORK/fake-patrol.sh" "$TS"
check "last-trigger が無ければ起動する" 'wait_mark'
check "last-trigger に今の時刻が書かれる" '[ -f "$TSTATE/last-trigger" ] && [ $(( $(cat "$TSTATE/last-trigger") - now )) -ge 0 ] && [ $(( $(cat "$TSTATE/last-trigger") - now )) -le 5 ]'
check "標準出力が空で終了コード0" '[ "$T_RC" -eq 0 ] && [ ! -s "$WORK/trigger.out" ]'

printf '%s\n' "$((now - 6 * 86400))" >"$TSTATE/last-trigger"
run_trigger "" "$WORK/fake-patrol.sh" "$TS"
sleep 1
check "既定の間隔（7日）未満なら起動しない" '[ ! -e "$MARK" ] && [ "$T_RC" -eq 0 ] && [ ! -s "$WORK/trigger.out" ]'
check "起動しないときは last-trigger を変えない" '[ "$(cat "$TSTATE/last-trigger")" = "$((now - 6 * 86400))" ]'

printf '%s\n' "$((now - 7 * 86400 - 10))" >"$TSTATE/last-trigger"
run_trigger "" "$WORK/fake-patrol.sh" "$TS"
check "7日以上たっていれば起動する" 'wait_mark'

printf 'broken\n' >"$TSTATE/last-trigger"
run_trigger "" "$WORK/fake-patrol.sh" "$TS"
check "last-trigger の中身が数字でなければ起動する" 'wait_mark'

printf '%s\n' "$((now - 2 * 86400))" >"$TSTATE/last-trigger"
run_trigger 3 "$WORK/fake-patrol.sh" "$TS"
sleep 1
check "SECRET_PATROL_INTERVAL_DAYS=3 では2日前なら起動しない" '[ ! -e "$MARK" ]'
run_trigger 1 "$WORK/fake-patrol.sh" "$TS"
check "SECRET_PATROL_INTERVAL_DAYS=1 では2日前なら起動する" 'wait_mark'

printf '%s\n' "$((now - 30 * 86400))" >"$TSTATE/last-trigger"
mkdir "$TSTATE/lock"
run_trigger "" "$WORK/fake-patrol.sh" "$TS"
sleep 1
check "lock があれば起動しない" '[ ! -e "$MARK" ] && [ "$T_RC" -eq 0 ] && [ ! -s "$WORK/trigger.out" ]'
check "lock を消さない" '[ -d "$TSTATE/lock" ]'
rmdir "$TSTATE/lock"

rm -rf "$TS"
t0="$(date +%s)"
run_trigger "" "$WORK/slow-patrol.sh" "$TS"
t1="$(date +%s)"
check "時間のかかるスクリプトでも1秒以内に戻る（実際: $((t1 - t0))秒）" '[ $((t1 - t0)) -le 1 ] && [ ! -e "$MARK" ]'
sleep 6
check "戻ったあと、裏で起動したスクリプトが最後まで動く" '[ -s "$MARK" ]'

mkdir -p "$WORK/ro"; : >"$WORK/ro/file"
run_trigger "" "$WORK/fake-patrol.sh" "$WORK/ro/file"
sleep 1
check "状態ディレクトリを作れなくても標準出力が空で終了コード0（起動しない）" \
  '[ "$T_RC" -eq 0 ] && [ ! -s "$WORK/trigger.out" ] && [ ! -e "$MARK" ]'

TH="$WORK/trigger-home"
rm -rf "$TS" "$TH"
mkdir -p "$TH/Documents" "$TH/Desktop"
chmod 000 "$TH/Documents"
SECRET_PATROL_HOME="$TH" run_trigger "" "$WORK/fake-patrol.sh" "$TS"
sleep 1
check "Documents を一覧できなければ起動しない" '[ ! -e "$MARK" ]'
check "Documents を一覧できなければ last-trigger を書かない" '[ ! -e "$TSTATE/last-trigger" ]'
check "Documents を一覧できなくても標準出力が空で終了コード0" '[ "$T_RC" -eq 0 ] && [ ! -s "$WORK/trigger.out" ]'
chmod 755 "$TH/Documents"
SECRET_PATROL_HOME="$TH" run_trigger "" "$WORK/fake-patrol.sh" "$TS"
check "権限を戻したあと、Downloads が無くても起動する" 'wait_mark'

# 書類などを見回らない設定では、Documents を ls しない（macOS の許可のダイアログを出さない）。
rm -rf "$TS"
chmod 000 "$TH/Documents"
printf 'PERSONAL_FOLDERS=no\nREPO_ROOTS=\n' >"$WORK/patrol-no.conf"
CLAUDE_REVIEW_PATROL_CONF="$WORK/patrol-no.conf" SECRET_PATROL_HOME="$TH" run_trigger "" "$WORK/fake-patrol.sh" "$TS"
check "PERSONAL_FOLDERS=no なら Documents を一覧できなくても起動する" 'wait_mark'
rm -rf "$TS"
CLAUDE_REVIEW_PATROL_CONF="$WORK/nosuch.conf" SECRET_PATROL_HOME="$TH" run_trigger "" "$WORK/fake-patrol.sh" "$TS"
check "設定ファイルが無ければ Documents を一覧できなくても起動する" 'wait_mark'
chmod 755 "$TH/Documents"
rm -rf "$TS"
mkdir -p "$TH/repos"; chmod 000 "$TH/repos"
printf 'PERSONAL_FOLDERS=no\nREPO_ROOTS=%s\n' "$TH/repos" >"$WORK/patrol-repo.conf"
CLAUDE_REVIEW_PATROL_CONF="$WORK/patrol-repo.conf" SECRET_PATROL_HOME="$TH" run_trigger "" "$WORK/fake-patrol.sh" "$TS"
sleep 1
check "リポジトリの置き場所を一覧できなければ起動しない" '[ ! -e "$MARK" ] && [ "$T_RC" -eq 0 ] && [ ! -s "$WORK/trigger.out" ]'
chmod 755 "$TH/repos"

echo "== 見回りの範囲（設定ファイル）"
rm -f "$FAKE_GITLEAKS_LOG"
out="$(CLAUDE_REVIEW_PATROL_CONF="$WORK/nosuch.conf" "$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "設定ファイルが無ければ書類などを見回らない" '! printf "%s" "$out" | grep -Fq "users.tsv" && printf "%s" "$out" | grep -Fq "書類・デスクトップ・ダウンロード: 見回らない"'
check "設定ファイルが無ければリポジトリを見回らない" '! grep -Fq "$H/Documents/git" "$FAKE_GITLEAKS_LOG" && ! grep -Fq "$H/dev" "$FAKE_GITLEAKS_LOG" && printf "%s" "$out" | grep -Fq "手元のリポジトリの置き場所: なし（見回らない）"'
check "設定ファイルが無くても Claude の記録は見回る" 'grep -Fq "$H/.claude" "$FAKE_GITLEAKS_LOG"'
rm -f "$FAKE_GITLEAKS_LOG"
printf 'PERSONAL_FOLDERS=no\nREPO_ROOTS=%s\n' "$H/dev" >"$WORK/patrol-dev.conf"
out="$(CLAUDE_REVIEW_PATROL_CONF="$WORK/patrol-dev.conf" "$SCRIPT_DIR/patrol.sh" --stdout 2>/dev/null)"
check "PERSONAL_FOLDERS=no なら書類などを見回らず、リポジトリの個人情報は数える" '! printf "%s" "$out" | grep -Fq "users.tsv" && printf "%s" "$out" | grep -Fq "~/dev/repo3/list.csv"'
check "REPO_ROOTS の外のリポジトリは見回らない" '! grep -Fq "$H/Documents/git" "$FAKE_GITLEAKS_LOG" && ! printf "%s" "$out" | grep -Fq "Documents/git"'

echo "== 実行権限"
for f in patrol.sh test.sh session-trigger.sh; do
  check "実行権限: $f" '[ -x "$SCRIPT_DIR/$f" ]'
done

echo
printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
