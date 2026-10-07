#!/bin/bash
# 秘密情報と個人情報の置き忘れを見回り、結果を Markdown のレポートへ書く。
# SessionStart フックの session-trigger.sh から、前回の起動から7日以上たったときに裏で呼ばれる。
# ネットワークは使わない。対象のファイルは読むだけで、書き換えない。
# 使い方: patrol.sh [--stdout] [--reset-baseline]
#   --stdout          レポートをファイルへ書かず標準出力へ出す。ログファイルを作らず、baseline も更新しない。
#   --reset-baseline  既知の指摘（baseline）を消してから見回る。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。jq は使わない。
set -u

# 呼び出し元の PATH を先に置く。test.sh が偽の gitleaks を先頭に置くためである。
export PATH="${PATH:+$PATH:}$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

JOB_NAME="secret-patrol"
SP_HOME="${SECRET_PATROL_HOME:-$HOME}"
SP_HOME="${SP_HOME%/}"
GITLEAKS="${SECRET_PATROL_GITLEAKS:-gitleaks}"
REPORTS_ROOT="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORTS_ROOT="${REPORTS_ROOT%/}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
STATE_DIR="${STATE_BASE%/}/$JOB_NAME"
BASELINE_DIR="$STATE_DIR/baseline"
LOG_KEEP=30
# 個人情報の候補とする、メールアドレスらしき文字列を含む行数の下限。
PII_MIN_LINES=20
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# 作業ツリーの見回りで除くディレクトリ。
TREE_EXCLUDES="node_modules cdk.out dist build .git vendor .next"
# 見回りの範囲の設定ファイル（install.sh が書く）。無ければ、書類・デスクトップ・ダウンロードと手元のリポジトリを見回らない。
# 書類などを不意に読むと、macOS がフォルダへのアクセスの許可を求めるためである。
PATROL_CONF="${CLAUDE_REVIEW_PATROL_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/patrol.conf}"

# 設定ファイルから値を1つ出す。先頭の ~/ は HOME に置き換える。ファイルが無ければ 1 を返す。
patrol_conf() {
  local v
  [ -f "$PATROL_CONF" ] || return 1
  v="$(sed -n "s/^$1=//p" "$PATROL_CONF" | tail -n 1)"
  case "$v" in "~/"*) v="$HOME/${v#\~/}" ;; esac
  printf '%s\n' "$v"
}
PERSONAL_FOLDERS="$(patrol_conf PERSONAL_FOLDERS)" || PERSONAL_FOLDERS=no
REPO_ROOTS="$(patrol_conf REPO_ROOTS)" || REPO_ROOTS=""

# 定期実行の共通の設定（jobs.conf）。環境変数が設定ファイルより優先する。値の先頭の ~ だけを展開する。
JOBS_CONF="${CLAUDE_REVIEW_JOBS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/jobs.conf}"
jobs_conf() {
  local v
  [ -f "$JOBS_CONF" ] || return 0
  v="$(sed -n "s/^$1=//p" "$JOBS_CONF" | tail -n 1)"
  case "$v" in '~'*) v="$HOME${v#\~}" ;; esac
  printf '%s' "$v"
}
# Claude の設定ディレクトリの一覧（コロン区切り）。2つ目の設定ディレクトリを使う場合はここに足す。
[ -n "${CLAUDE_REVIEW_CONFIG_DIRS:-}" ] || CLAUDE_REVIEW_CONFIG_DIRS="$(jobs_conf CLAUDE_REVIEW_CONFIG_DIRS)"
[ -n "$CLAUDE_REVIEW_CONFIG_DIRS" ] || CLAUDE_REVIEW_CONFIG_DIRS="$SP_HOME/.claude"
# スキルの置き場所の直下で見回らない名前（空白区切り）。同期やプラグインの置き場所を指定する。
[ -n "${SECRET_PATROL_SKILL_EXCLUDES:-}" ] || SECRET_PATROL_SKILL_EXCLUDES="$(jobs_conf SECRET_PATROL_SKILL_EXCLUDES)"
# PreToolUse のフックのうち、秘密の検査とみなすコマンドに含まれる文字列。空なら確かめない。
[ -n "${SECRET_PATROL_HOOK_PATTERN:-}" ] || SECRET_PATROL_HOOK_PATTERN="$(jobs_conf SECRET_PATROL_HOOK_PATTERN)"
CONFIG_DIRS=()
while IFS= read -r d; do
  case "$d" in '~'*) d="$HOME${d#\~}" ;; esac
  [ -n "$d" ] && CONFIG_DIRS+=("${d%/}")
done < <(printf '%s\n' "$CLAUDE_REVIEW_CONFIG_DIRS" | tr ':' '\n')

log_error() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_info() {
  printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

to_stdout=0
reset_baseline=0
for arg in "$@"; do
  case "$arg" in
    --stdout) to_stdout=1 ;;
    --reset-baseline) reset_baseline=1 ;;
    *) log_error "不明な引数です: ${arg}"; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR/logs" || exit 1

LOCK_DIR="$STATE_DIR/lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_error "別の実行が進行中です（${LOCK_DIR} が存在します）"
  exit 1
fi
# gitleaks の結果（値を含みうる）はすべて WORK に置き、終了時に消す。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/secret-patrol.XXXXXX")" || { rmdir "$LOCK_DIR"; exit 1; }
# 作業ツリーの見回りで、コミットされうるファイルへのリンクを並べるディレクトリ。
# baseline の指紋にパスが入るため、実行ごとに変わらない場所に置く。lock の間だけ使う。
TREE_DIR="$STATE_DIR/tree"
trap 'rm -rf "$WORK" "$TREE_DIR"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
rm -rf "$TREE_DIR"

if [ "$to_stdout" -eq 0 ]; then
  LOG_FILE="$STATE_DIR/logs/$(date '+%Y-%m-%d-%H%M%S').log"
  exec >>"$LOG_FILE" 2>&1
  # 古いログを LOG_KEEP 件まで減らす。削除してよいのはログだけである。
  ls -1t "$STATE_DIR/logs/"*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)) | while IFS= read -r old; do
    rm -f -- "$old"
  done
fi

if [ "$reset_baseline" -eq 1 ]; then
  rm -f "$BASELINE_DIR"/*.json
  log_info "baseline を消しました: ${BASELINE_DIR}"
fi
mkdir -p "$BASELINE_DIR" || exit 1

# JSON の解析は osascript（JavaScript）で行う。jq は無い前提とし、launchd の下で python3 を使わない。
# 出力は1件1行のタブ区切りで、値（Secret・Match）は出さない。解析できなければ ERR を出す。
JSON_JS="$WORK/json.js"
cat >"$JSON_JS" <<'EOF'
ObjC.import('Foundation');
function load(p) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null);
  if (s.isNil()) throw new Error('read');
  return JSON.parse(ObjC.unwrap(s));
}
function clean(v) {
  return String(v === undefined || v === null ? '' : v).replace(/[\t\r\n]/g, ' ');
}
function run(argv) {
  var data;
  try { data = load(argv[1]); } catch (e) { return 'ERR'; }
  if (argv[0] === 'count') {
    return Array.isArray(data) ? String(data.length) : 'ERR';
  }
  if (argv[0] === 'findings') {
    if (!Array.isArray(data)) return 'ERR';
    return data.map(function (f) {
      return [clean(f.File), clean(f.StartLine), clean(f.RuleID), clean(f.Commit)].join('\t');
    }).join('\n');
  }
  if (argv[0] === 'settings') {
    var pattern = argv[2];
    var need = argv.slice(3);
    var deny = (data && data.permissions && Array.isArray(data.permissions.deny)) ? data.permissions.deny : [];
    var absent = need.filter(function (x) { return deny.indexOf(x) < 0; });
    // 古い書き方（Read(**/…)）は作業場所からの相対で、作業場所の外を止めない。設定済みに数えず、未設定と分けて返す。
    var old = [], missing = [];
    absent.forEach(function (x) {
      var o = x.indexOf('Read(//**/') === 0 ? 'Read(' + x.slice('Read(//'.length) : null;
      if (o !== null && deny.indexOf(o) >= 0) old.push(o); else missing.push(x);
    });
    // 判定の文字列が無ければ、フックは確かめない（2 を返す）。
    var hook = pattern ? 0 : 2;
    var pre = (data && data.hooks && Array.isArray(data.hooks.PreToolUse)) ? data.hooks.PreToolUse : [];
    pre.forEach(function (m) {
      (m && Array.isArray(m.hooks) ? m.hooks : []).forEach(function (h) {
        if (pattern && h && typeof h.command === 'string' && h.command.indexOf(pattern) >= 0) hook = 1;
      });
    });
    return [need.length - absent.length, hook, missing.join(' ') || '-', old.join(' ') || '-'].join('\t');
  }
  return 'ERR';
}
EOF

json() {
  osascript -l JavaScript "$JSON_JS" "$@" 2>/dev/null
}

# 表のセルに入れる文字列から、表を壊す文字を取り除く。
cell() {
  local s="$1"
  s="${s//|/\\|}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

# 結果に書くパスは、見回りの起点を ~ に置き換える。
disp() {
  local p="$1"
  case "$p" in
    "$SP_HOME"/*) printf '~/%s' "${p#$SP_HOME/}" ;;
    "$SP_HOME") printf '~' ;;
    *) printf '%s' "$p" ;;
  esac
}

# baseline のファイル名に使える形にする。
key_of() {
  local p="$1"
  p="${p#$SP_HOME/}"
  printf '%s' "$p" | tr -c 'A-Za-z0-9._-' '_'
}

# 正規表現の特殊文字を逃がす。
re_escape() {
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'
}

# エラー出力から、読めなかった理由を決める。値を含みうるので、出力そのものは結果に書かない。
deny_reason() {
  if grep -qi 'operation not permitted' "$1" 2>/dev/null; then
    printf 'Operation not permitted'
  elif grep -qi 'permission denied' "$1" 2>/dev/null; then
    printf 'Permission denied'
  fi
}

# 読めなかった対象を記録する。理由に値を含めないこと。
add_unreadable() {
  printf '| %s | %s |\n' "$(cell "$(disp "$1")")" "$(cell "$2")" >>"$WORK/unreadable"
  log_error "読めなかった対象: $(disp "$1"): $2"
}

# ディレクトリが一覧できるかを確かめる。できなければ読めなかった対象に入れて 1 を返す。
check_readable_dir() {
  local why
  if ! ls "$1" >/dev/null 2>"$WORK/ls.err"; then
    why="$(deny_reason "$WORK/ls.err")"
    add_unreadable "$1" "${why:-一覧できませんでした}"
    return 1
  fi
  return 0
}

# gitleaks の設定ファイルを作る。既定のルールは残し、引数の正規表現に当たるパスを除く。
write_config() {
  local out="$1" re
  shift
  {
    printf '[extend]\nuseDefault = true\n'
    # gitleaks 8.30 は空の allowlist を含む設定を読み込めない。除外が無ければ allowlist を書かない。
    if [ "$#" -gt 0 ]; then
      printf '\n[allowlist]\npaths = [\n'
      for re in "$@"; do
        printf "  '''%s''',\n" "$re"
      done
      printf ']\n'
    fi
  } >"$out"
}

have_gitleaks=0
if command -v "$GITLEAKS" >/dev/null 2>&1; then
  have_gitleaks=1
else
  log_error "gitleaks が見つかりません（${GITLEAKS}）。秘密の見回り（a・b）を行いません"
fi

# 区分ごとの新規・既知の件数。a=Claude 自身の記録、bt=作業ツリー、bg=未push のコミット。
a_new=0; a_known=0; bt_new=0; bt_known=0; bg_new=0; bg_known=0

# gitleaks を1つの対象に対して走らせ、新規の指摘を WORK/new に追記する。
# 引数: 区分（a・bt・bg） baseline の名前 表示名 表示の接頭辞 gitleaks のサブコマンドと引数…
# 結果を S_NEW・S_KNOWN に入れる。失敗したら 1 を返す。
scan() {
  local cat="$1" key="$2" label="$3" prefix="$4"
  shift 4
  local base="$BASELINE_DIR/$cat-$key.json" rep="$WORK/report.json" full="$WORK/full.json"
  local err="$WORK/gitleaks.err" rc n file line rule commit loc why catname
  S_NEW=0; S_KNOWN=0
  rm -f "$rep" "$full"

  if [ -f "$base" ]; then
    n="$(json count "$base")"
    case "$n" in
      ''|*[!0-9]*)
        log_info "baseline を解析できないため使いません: ${base}"
        base_ok=0 ;;
      *) S_KNOWN="$n"; base_ok=1 ;;
    esac
  else
    base_ok=0
  fi

  if [ "$base_ok" -eq 1 ]; then
    "$GITLEAKS" "$@" --no-banner --redact --exit-code 0 --report-format json --report-path "$rep" --baseline-path "$base" >/dev/null 2>"$err"
  else
    "$GITLEAKS" "$@" --no-banner --redact --exit-code 0 --report-format json --report-path "$rep" >/dev/null 2>"$err"
  fi
  rc=$?
  why="$(deny_reason "$err")"
  if [ "$rc" -ne 0 ] || [ ! -f "$rep" ]; then
    add_unreadable "$label" "${why:-gitleaks が失敗しました（終了コード ${rc}）}"
    return 1
  fi
  if [ -n "$why" ]; then
    # 一部のファイルが読めなかった。読めた分の結果は使う。
    add_unreadable "$label" "${why}（一部のファイル）"
  fi

  if ! json findings "$rep" >"$WORK/findings.tsv" || [ "$(head -1 "$WORK/findings.tsv")" = "ERR" ]; then
    add_unreadable "$label" "gitleaks の結果を解析できませんでした"
    return 1
  fi
  case "$cat" in
    a) catname="a" ;;
    bt) catname="b（作業ツリー）" ;;
    bg) catname="b（未push）" ;;
  esac
  while IFS="$(printf '\t')" read -r file line rule commit; do
    [ -n "$file$rule" ] || continue
    S_NEW=$((S_NEW + 1))
    case "$file" in
      "$TREE_DIR"/*) loc="${prefix}${file#"$TREE_DIR"/}" ;;
      /*) loc="$(disp "$file")" ;;
      *) loc="${prefix}${file}" ;;
    esac
    if [ "$cat" = "bg" ]; then commit="${commit:0:7}"; else commit="-"; fi
    printf '| %s | %s:%s | %s | %s |\n' "$catname" "$(cell "$loc")" "$(cell "$line")" "$(cell "$rule")" "$(cell "$commit")" >>"$WORK/new"
  done <"$WORK/findings.tsv"

  # 初回は今回の結果を、新規が出たら今回の全件を baseline にする。--stdout では更新しない。
  [ "$to_stdout" -eq 1 ] && return 0
  if [ "$base_ok" -eq 0 ]; then
    cp "$rep" "$base" || log_error "baseline を書けませんでした: ${base}"
  elif [ "$S_NEW" -gt 0 ]; then
    if "$GITLEAKS" "$@" --no-banner --redact --exit-code 0 --report-format json --report-path "$full" >/dev/null 2>"$err" && [ -f "$full" ]; then
      cp "$full" "$base" || log_error "baseline を書けませんでした: ${base}"
    else
      log_error "baseline を更新するための全件の取得に失敗しました: ${label}"
    fi
  fi
  return 0
}

# ---- a. Claude 自身の記録 ----
if [ "$have_gitleaks" -eq 1 ]; then
  # 設定ディレクトリごとのメモリ・スキル・CLAUDE.md・rules・settings.json。リンクで同じ実体を指すものは最初の1つだけ見る。
  seen_reals=" "
  for c in "${CONFIG_DIRS[@]}"; do
    for t in "$c"/projects/*/memory "$c/skills" "$c/CLAUDE.md" "$c/rules" "$c/settings.json"; do
      printf '%s\n' "$t"
    done
  done >"$WORK/targets-a"
  while IFS= read -r t; do
    [ -e "$t" ] || continue
    # リンクは gitleaks が辿らないため、実体のパスを渡す。
    real="$(readlink -f "$t" 2>/dev/null)"
    real="${real:-$t}"
    case "$seen_reals" in *" $real "*) continue ;; esac
    seen_reals="$seen_reals$real "
    if [ -d "$real" ]; then
      check_readable_dir "$real" || continue
    elif [ ! -r "$real" ]; then
      add_unreadable "$t" "Permission denied"
      continue
    fi
    cfg="$WORK/config-a.toml"
    if [ "${t##*/}" = "skills" ]; then
      root="$(re_escape "$real")"
      # . で始まるディレクトリ、*/history/、SECRET_PATROL_SKILL_EXCLUDES の名前を除く。
      excl=()
      for n in $SECRET_PATROL_SKILL_EXCLUDES; do excl+=("^(${root}/)?$(re_escape "$n")/"); done
      write_config "$cfg" "^(${root}/)?([^/]+/)*\\.[^/]+/" ${excl[@]+"${excl[@]}"} "^(${root}/)?([^/]+/)+history/"
    else
      write_config "$cfg"
    fi
    if scan a "$(key_of "$t")" "$t" "" dir --config "$cfg" "$real"; then
      a_new=$((a_new + S_NEW)); a_known=$((a_known + S_KNOWN))
    fi
  done <"$WORK/targets-a"
fi

# ---- b. 手元のリポジトリ ----
# 設定ファイルの REPO_ROOTS（コロン区切り）の各フォルダの直下、およびその1段下で .git を持つディレクトリ。
: >"$WORK/repos"
printf '%s\n' "$REPO_ROOTS" | tr ':' '\n' >"$WORK/repo-roots"
while IFS= read -r root; do
  case "$root" in "~/"*) root="$HOME/${root#\~/}" ;; esac
  root="${root%/}"
  [ -n "$root" ] && [ -d "$root" ] || continue
  check_readable_dir "$root" || continue
  for p in "$root"/*; do
    [ -d "$p" ] || continue
    if [ -e "$p/.git" ]; then
      printf '%s\n' "$p" >>"$WORK/repos"
      continue
    fi
    for q in "$p"/*; do
      [ -d "$q" ] && [ -e "$q/.git" ] && printf '%s\n' "$q" >>"$WORK/repos"
    done
  done
done <"$WORK/repo-roots"

tree_res=""
for d in $TREE_EXCLUDES; do
  tree_res="${tree_res}${tree_res:+|}$(re_escape "$d")"
done
TREE_CFG="$WORK/config-tree.toml"
write_config "$TREE_CFG" "(^|/)(${tree_res})(/|\$)"

if [ "$have_gitleaks" -eq 1 ]; then
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    key="$(key_of "$repo")"
    name="$(disp "$repo")"
    # 作業ツリーは、コミットされうるファイル（追跡中のものと、追跡していないが無視もされていないもの）だけを見る。
    # 入れ子のリポジトリ（末尾が / の行）、作業ツリーに無いファイル、シンボリックリンクは除く。
    # 各ファイルへのリンクを同じ相対パスで TREE_DIR に並べ、gitleaks にリンクを辿らせる。
    if git --no-optional-locks -C "$repo" ls-files -z -co --exclude-standard >"$WORK/ls-files" 2>"$WORK/git.err"; then
      why="$(deny_reason "$WORK/git.err")"
      [ -n "$why" ] && add_unreadable "$repo" "${why}（一部のファイル）"
      rm -rf "$TREE_DIR"
      mkdir -p "$TREE_DIR"
      while IFS= read -r -d '' rel; do
        case "$rel" in ''|*/) continue ;; esac
        [ -L "$repo/$rel" ] && continue
        [ -f "$repo/$rel" ] || continue
        case "$rel" in */*) mkdir -p "$TREE_DIR/${rel%/*}" ;; esac
        ln -s "$repo/$rel" "$TREE_DIR/$rel"
      done <"$WORK/ls-files"
      if scan bt "tree-$key" "$repo" "${name}/" dir --follow-symlinks --config "$TREE_CFG" "$TREE_DIR"; then
        bt_new=$((bt_new + S_NEW)); bt_known=$((bt_known + S_KNOWN))
      fi
      rm -rf "$TREE_DIR"
    else
      why="$(deny_reason "$WORK/git.err")"
      add_unreadable "$repo" "${why:-git ls-files が失敗しました}"
    fi

    # push していないコミット。上流が無ければ、どのリモートにも無いコミットを見る。
    if git --no-optional-locks -C "$repo" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
      range="@{u}..HEAD"
      cnt="$(git --no-optional-locks -C "$repo" rev-list --count '@{u}..HEAD' 2>"$WORK/git.err")"
    else
      range="--branches --not --remotes"
      cnt="$(git --no-optional-locks -C "$repo" rev-list --count --branches --not --remotes 2>"$WORK/git.err")"
    fi
    case "$cnt" in
      ''|*[!0-9]*)
        why="$(deny_reason "$WORK/git.err")"
        add_unreadable "$repo" "${why:-git rev-list が失敗しました}"
        continue ;;
    esac
    if [ "$cnt" -eq 0 ]; then
      # 対象のコミットが無い。既知の件数だけを数える。
      if [ -f "$BASELINE_DIR/bg-git-$key.json" ]; then
        n="$(json count "$BASELINE_DIR/bg-git-$key.json")"
        case "$n" in ''|*[!0-9]*) ;; *) bg_known=$((bg_known + n)) ;; esac
      fi
      continue
    fi
    if scan bg "git-$key" "$repo" "${name}/" git "--log-opts=$range" "$repo"; then
      bg_new=$((bg_new + S_NEW)); bg_known=$((bg_known + S_KNOWN))
    fi
  done <"$WORK/repos"
fi

# ---- c. 個人情報の置き忘れ ----
# 対象のファイルの一覧を作る。find の読めなかったディレクトリは読めなかった対象に入れる。
: >"$WORK/pii-files"
find_files() {
  local root="$1"
  shift
  find "$root" "$@" -type f \( -iname '*.tsv' -o -iname '*.csv' -o -iname '*.txt' -o -iname '*.json' \) -print \
    >>"$WORK/pii-files" 2>"$WORK/find.err"
  while IFS= read -r line; do
    case "$line" in
      "find: "*": "*)
        p="${line#find: }"
        add_unreadable "${p%: *}" "${p##*: }" ;;
    esac
  done <"$WORK/find.err"
}
# 書類・デスクトップ・ダウンロードは、設定ファイルの PERSONAL_FOLDERS が yes のときだけ見回る。
scanned_documents=0
if [ "$PERSONAL_FOLDERS" = "yes" ]; then
  for root in "$SP_HOME/Downloads" "$SP_HOME/Desktop"; do
    [ -d "$root" ] || continue
    find_files "$root"
  done
  if [ -d "$SP_HOME/Documents" ]; then
    find_files "$SP_HOME/Documents" \( -path "$SP_HOME/Documents/git/*" \( -name .git -o -name node_modules \) -prune \) -o
    scanned_documents=1
  fi
fi
# リポジトリの作業ツリーは b と同じディレクトリを除く。書類を見回ったときは、その中のものは上で数えている。
while IFS= read -r root; do
  [ -n "$root" ] || continue
  if [ "$scanned_documents" -eq 1 ]; then
    case "$root" in "$SP_HOME/Documents/"*) continue ;; esac
  fi
  set --
  for d in $TREE_EXCLUDES; do
    [ $# -gt 0 ] && set -- "$@" -o
    set -- "$@" -name "$d"
  done
  find_files "$root" \( \( "$@" \) -prune \) -o
done <"$WORK/repos"

sort -u "$WORK/pii-files" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -r "$f" ]; then
    add_unreadable "$f" "Permission denied"
    continue
  fi
  # 中身は数えるだけで、どこにも書かない。example.com・example.org・example.net のドメインは数えない。
  hits="$(LC_ALL=C grep -I -E -o -n "$EMAIL_RE" "$f" 2>"$WORK/grep.err" \
    | LC_ALL=C grep -E -v '@([A-Za-z0-9-]+\.)*example\.(com|org|net)$' | cut -d: -f1 | sort -u | wc -l | tr -d ' ')"
  why="$(deny_reason "$WORK/grep.err")"
  if [ -n "$why" ]; then
    add_unreadable "$f" "$why"
    continue
  fi
  [ "${hits:-0}" -ge "$PII_MIN_LINES" ] || continue
  total_lines="$(wc -l <"$f" | tr -d ' ')"
  mtime="$(stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null)"
  printf '| %s | %s | %s | %s |\n' "$(cell "$(disp "$f")")" "$total_lines" "$hits" "${mtime:-不明}" >>"$WORK/pii"
done

# ---- d. 守りの設定 ----
# Read(**/…) は作業場所からの相対で、作業場所の外を止めない。どこでも止める Read(//**/…) を求める。
DENY_NEED=('Read(//**/.env)' 'Read(//**/.env.*)' 'Read(~/.aws/credentials)' 'Read(~/.ssh/**)' 'Read(//**/*.pem)' 'Read(//**/*.key)')
: >"$WORK/guard"
for c in "${CONFIG_DIRS[@]}"; do
  s="$c/settings.json"
  if [ ! -e "$s" ]; then
    printf '| %s | ファイルが存在しません | - |\n' "$(cell "$(disp "$s")")" >>"$WORK/guard"
    continue
  fi
  res="$(json settings "$s" "$SECRET_PATROL_HOOK_PATTERN" "${DENY_NEED[@]}")"
  if [ -z "$res" ] || [ "$res" = "ERR" ]; then
    if [ ! -r "$s" ]; then
      add_unreadable "$s" "Permission denied"
    else
      add_unreadable "$s" "JSON として解析できませんでした"
    fi
    printf '| %s | 確認できませんでした | 確認できませんでした |\n' "$(cell "$(disp "$s")")" >>"$WORK/guard"
    continue
  fi
  deny_n="$(printf '%s' "$res" | cut -f1)"
  hook="$(printf '%s' "$res" | cut -f2)"
  missing="$(printf '%s' "$res" | cut -f3)"
  old_items="$(printf '%s' "$res" | cut -f4)"
  [ "$missing" = "-" ] && missing=""
  [ "$old_items" = "-" ] && old_items=""
  deny_txt="6つ中${deny_n}つ"
  notes=""
  [ -n "$missing" ] && notes="未設定: $(printf '%s' "$missing" | sed 's/ /、/g')"
  [ -n "$old_items" ] && notes="${notes:+${notes}、}書き方が古い（作業場所の外を止めない）: $(printf '%s' "$old_items" | sed 's/ /、/g')"
  [ -n "$notes" ] && deny_txt="${deny_txt}（${notes}）"
  case "$hook" in
    1) hook_txt="あり" ;;
    2) hook_txt="確かめていない（SECRET_PATROL_HOOK_PATTERN が未設定）" ;;
    *) hook_txt="なし（未設定）" ;;
  esac
  printf '| %s | %s | %s |\n' "$(cell "$(disp "$s")")" "$(cell "$deny_txt")" "$hook_txt" >>"$WORK/guard"
done

count_lines() {
  if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else printf '0'; fi
}

build_report() {
  local skipped=""
  [ "$have_gitleaks" -eq 1 ] || skipped="（gitleaks が無いため調べていない）"
  printf '# 秘密情報と個人情報の見回りレポート\n\n'
  printf -- '- 作成日時: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf -- '- 対象の起点: %s\n' "$SP_HOME"
  if [ "$PERSONAL_FOLDERS" = "yes" ]; then
    printf -- '- 書類・デスクトップ・ダウンロード: 見回る\n'
  else
    printf -- '- 書類・デスクトップ・ダウンロード: 見回らない（設定ファイル %s）\n' "$PATROL_CONF"
  fi
  printf -- '- 手元のリポジトリの置き場所: %s\n\n' "${REPO_ROOTS:-なし（見回らない）}"
  printf '| 区分 | 新規 | 既知 |\n'
  printf '| --- | --- | --- |\n'
  printf '| a. Claude 自身の記録%s | %s | %s |\n' "$skipped" "$a_new" "$a_known"
  printf '| b. リポジトリの作業ツリー%s | %s | %s |\n' "$skipped" "$bt_new" "$bt_known"
  printf '| b. push していないコミット%s | %s | %s |\n' "$skipped" "$bg_new" "$bg_known"
  printf '| c. 個人情報の置き忘れの候補 | %s | - |\n' "$(count_lines "$WORK/pii")"
  printf '| 読めなかった対象 | %s | - |\n' "$(count_lines "$WORK/unreadable")"

  printf '\n## 新規の秘密\n\n'
  if [ -s "$WORK/new" ]; then
    printf '値は記載しない。該当の箇所を開いて確かめること。\n\n'
    printf '| 区分 | ファイル:行 | ルール名 | コミット |\n'
    printf '| --- | --- | --- | --- |\n'
    cat "$WORK/new"
  else
    printf '該当なし\n'
  fi

  printf '\n## 個人情報の置き忘れの候補\n\n'
  if [ -s "$WORK/pii" ]; then
    printf 'メールアドレスらしき文字列を含む行が%s行以上あるファイル。中身は記載しない。\n\n' "$PII_MIN_LINES"
    printf '| パス | 行数 | 該当行の件数 | 最終更新日 |\n'
    printf '| --- | --- | --- | --- |\n'
    cat "$WORK/pii"
  else
    printf '該当なし\n'
  fi

  printf '\n## 守りの設定\n\n'
  printf '| ファイル | permissions.deny | gitleaks の hook |\n'
  printf '| --- | --- | --- |\n'
  cat "$WORK/guard"

  printf '\n## 読めなかった対象\n\n'
  if [ -s "$WORK/unreadable" ]; then
    printf '| パス | 理由 |\n'
    printf '| --- | --- |\n'
    cat "$WORK/unreadable"
  else
    printf '該当なし\n'
  fi

  printf '\n## 既知\n\n'
  if [ $((a_known + bt_known + bg_known)) -gt 0 ]; then
    printf -- '- a. Claude 自身の記録: %s件\n' "$a_known"
    printf -- '- b. リポジトリの作業ツリー: %s件\n' "$bt_known"
    printf -- '- b. push していないコミット: %s件\n' "$bg_known"
  else
    printf '該当なし\n'
  fi
}

failed=0
[ "$have_gitleaks" -eq 1 ] || failed=1
[ -s "$WORK/unreadable" ] && failed=1

if [ "$to_stdout" -eq 1 ]; then
  build_report
  exit "$failed"
fi

mkdir -p "$REPORTS_ROOT/$JOB_NAME" || exit 1
day="$(date '+%Y-%m-%d')"
report="$REPORTS_ROOT/$JOB_NAME/$day.md"
if [ -e "$report" ]; then
  n=2
  while [ -e "$REPORTS_ROOT/$JOB_NAME/$day-$n.md" ]; do n=$((n + 1)); done
  report="$REPORTS_ROOT/$JOB_NAME/$day-$n.md"
fi
if ! build_report >"$report"; then
  log_error "レポートを書けませんでした: ${report}"
  exit 1
fi
log_info "レポートを書きました: ${report}（新規 $((a_new + bt_new + bg_new))件、個人情報の候補 $(count_lines "$WORK/pii")件）"
if [ "$failed" -eq 1 ]; then
  log_error "見回りを終えられなかった対象があります。レポートの「読めなかった対象」を確かめてください"
  exit 1
fi
exit 0
