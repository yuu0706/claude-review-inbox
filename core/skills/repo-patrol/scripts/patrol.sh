#!/bin/bash
# 手元の git リポジトリを巡回し、状態を Markdown のレポートへ書く。SessionStart の hook から run-if-due.sh を経て1日1回呼ばれる。
# ネットワークに触れる git コマンドは使わない。すべて git -C <リポジトリ> の読み取りで行う。
# 使い方: patrol.sh [--stdout]
#   --stdout  レポートをファイルへ書かず標準出力へ出す。ログファイルも作らない。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。
set -u

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

JOB_NAME="repo-patrol"
# 巡回の対象。REPO_PATROL_ROOT が無ければ、見回りの範囲の設定ファイル（install.sh が書く）の REPO_ROOTS の先頭を使う。
# どちらも無ければ巡回しない。対象を決め打ちで読むと、macOS がフォルダへのアクセスの許可を求めることがあるためである。
PATROL_CONF="${CLAUDE_REVIEW_PATROL_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/patrol.conf}"
if [ -n "${REPO_PATROL_ROOT:-}" ]; then
  PATROL_ROOT="$REPO_PATROL_ROOT"
elif [ -f "$PATROL_CONF" ]; then
  PATROL_ROOT="$(sed -n 's/^REPO_ROOTS=//p' "$PATROL_CONF" | tail -n 1)"
  PATROL_ROOT="${PATROL_ROOT%%:*}"
  case "$PATROL_ROOT" in "~/"*) PATROL_ROOT="$HOME/${PATROL_ROOT#\~/}" ;; esac
else
  PATROL_ROOT=""
fi
PATROL_ROOT="${PATROL_ROOT%/}"
REPORTS_ROOT="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORTS_ROOT="${REPORTS_ROOT%/}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
STATE_DIR="${STATE_BASE%/}/$JOB_NAME"
LOG_KEEP=30

log_error() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_info() {
  printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_warn() {
  printf '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

to_stdout=0
for arg in "$@"; do
  case "$arg" in
    --stdout) to_stdout=1 ;;
    *) log_error "不明な引数です: ${arg}"; exit 2 ;;
  esac
done

if [ -z "$PATROL_ROOT" ]; then
  log_info "巡回の対象が設定されていないため、巡回しません（設定ファイル ${PATROL_CONF} の REPO_ROOTS）"
  exit 0
fi

mkdir -p "$STATE_DIR/logs" || exit 1

LOCK_DIR="$STATE_DIR/lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_error "別の実行が進行中です（${LOCK_DIR} が存在します）"
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-patrol.XXXXXX")" || { rmdir "$LOCK_DIR"; exit 1; }
trap 'rm -rf "$WORK"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT

if [ "$to_stdout" -eq 0 ]; then
  LOG_FILE="$STATE_DIR/logs/$(date '+%Y-%m-%d-%H%M%S').log"
  exec >>"$LOG_FILE" 2>&1
  # 古いログを LOG_KEEP 件まで減らす。削除してよいのはログだけである。
  ls -1t "$STATE_DIR/logs/"*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)) | while IFS= read -r old; do
    rm -f -- "$old"
  done
fi

if [ ! -d "$PATROL_ROOT" ]; then
  log_error "巡回の対象ディレクトリが存在しません: ${PATROL_ROOT}"
  exit 1
fi

# 同日の2回目以降は <日付>-2.md、<日付>-3.md と連番にする。
next_report_path() {
  local dir="$1" day n
  day="$(date '+%Y-%m-%d')"
  if [ ! -e "$dir/$day.md" ]; then
    printf '%s\n' "$dir/$day.md"
    return 0
  fi
  n=2
  while [ -e "$dir/$day-$n.md" ]; do n=$((n + 1)); done
  printf '%s\n' "$dir/$day-$n.md"
}

# 表のセルに入れる文字列から、表を壊す文字を取り除く。
cell() {
  local s="$1"
  s="${s//|/\\|}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

g() {
  git --no-optional-locks -C "$repo" "$@"
}

# 1つのリポジトリを調べ、結果を WORK 配下の一覧へ追記する。失敗したら 1 を返し、理由を FAIL_REASON に入れる。
inspect_repo() {
  local name="$1" err branch head_sha status_out staged unstaged untracked line x y
  local stash upstream ab ahead behind updiff unpushed refname up cnt
  local default_ref merged b common_dir fetch_at
  FAIL_REASON=""
  err="$WORK/err"

  if ! g rev-parse --git-dir >/dev/null 2>"$err"; then
    FAIL_REASON="git rev-parse が失敗しました: $(head -1 "$err")"
    return 1
  fi

  branch="$(g symbolic-ref --short -q HEAD 2>/dev/null)"
  if [ -z "$branch" ]; then
    head_sha="$(g rev-parse --short HEAD 2>/dev/null)"
    branch="(detached HEAD ${head_sha:-不明})"
  fi

  if ! status_out="$(g status --porcelain 2>"$err")"; then
    FAIL_REASON="git status が失敗しました: $(head -1 "$err")"
    return 1
  fi
  staged=0; unstaged=0; untracked=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    x="${line:0:1}"; y="${line:1:1}"
    if [ "$x$y" = "??" ]; then
      untracked=$((untracked + 1))
      continue
    fi
    [ "$x" != " " ] && staged=$((staged + 1))
    [ "$y" != " " ] && unstaged=$((unstaged + 1))
  done <<EOF
$status_out
EOF

  stash="$(g stash list 2>/dev/null | wc -l | tr -d ' ')"

  upstream="$(g rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  if [ -n "$upstream" ] && ab="$(g rev-list --left-right --count "HEAD...@{u}" 2>/dev/null)"; then
    ahead="${ab%%[[:space:]]*}"
    behind="${ab##*[[:space:]]}"
    updiff="${upstream}: ahead ${ahead} / behind ${behind}"
  else
    ahead=0
    updiff="上流なし"
  fi

  # push していないコミットがあるローカルブランチ。上流なしのブランチも含める。
  unpushed=""
  while IFS='|' read -r refname up; do
    [ -n "$refname" ] || continue
    if [ -z "$up" ]; then
      unpushed="${unpushed}${unpushed:+, }${refname}（上流なし）"
      continue
    fi
    if ! cnt="$(g rev-list --count "${up}..refs/heads/${refname}" 2>/dev/null)"; then
      unpushed="${unpushed}${unpushed:+, }${refname}（上流の参照なし）"
      continue
    fi
    [ "$cnt" -gt 0 ] && unpushed="${unpushed}${unpushed:+, }${refname}（${cnt}件）"
  done <<EOF
$(g for-each-ref --format='%(refname:short)|%(upstream)' refs/heads 2>/dev/null)
EOF

  # 既定ブランチ。origin/HEAD が指すもの、無ければ main・master・develop の順で存在するもの。
  default_ref="$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$default_ref" ]; then
    for b in main master develop; do
      if g show-ref --verify -q "refs/heads/$b"; then
        default_ref="$b"
        break
      fi
    done
  fi
  merged=""
  if [ -n "$default_ref" ]; then
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      [ "$b" = "$branch" ] && continue
      [ "$b" = "$default_ref" ] && continue
      [ "$b" = "${default_ref#origin/}" ] && continue
      merged="${merged}${merged:+, }${b}"
    done <<EOF
$(g for-each-ref --format='%(refname:short)' --merged "$default_ref" refs/heads 2>/dev/null)
EOF
  fi

  common_dir="$(cd "$PATROL_ROOT/$name" && cd "$(g rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
  if [ -n "$common_dir" ] && [ -f "$common_dir/FETCH_HEAD" ]; then
    fetch_at="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$common_dir/FETCH_HEAD" 2>/dev/null)"
  fi
  fetch_at="${fetch_at:-不明}"

  if [ $((staged + unstaged + untracked)) -gt 0 ] || [ "$stash" -gt 0 ] || [ "$ahead" -gt 0 ] || [ -n "$unpushed" ]; then
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$(cell "$name")" "$(cell "$branch")" "$staged" "$unstaged" "$untracked" "$stash" \
      "$(cell "$updiff")" "$(cell "${unpushed:-なし}")" "$fetch_at" >>"$WORK/action"
    acted=1
  else
    acted=0
  fi
  if [ -n "$merged" ]; then
    printf '| %s | %s | %s |\n' "$(cell "$name")" "$(cell "$default_ref")" "$(cell "$merged")" >>"$WORK/cleanup"
  fi
  if [ "$acted" -eq 0 ] && [ -z "$merged" ]; then
    printf -- '- %s（%s、最終取得 %s）\n' "$name" "$branch" "$fetch_at" >>"$WORK/ok"
  fi
  return 0
}

# ls の標準エラーから、読めなかった理由を取り出す。
deny_reason() {
  if grep -qi 'operation not permitted' "$1" 2>/dev/null; then
    printf 'Operation not permitted'
  elif grep -qi 'permission denied' "$1" 2>/dev/null; then
    printf 'Permission denied'
  fi
}

# ディレクトリが一覧できるかを確かめる。できなければ読めなかったフォルダに入れ、理由を UNREADABLE_WHY に入れて 1 を返す。
# launchd から起動すると TCC により一覧を拒否されることがあり、そのとき glob は展開されずに空振りする。
# glob の結果では拒否と空のフォルダを区別できないため、先に ls で確かめる。
check_readable_dir() {
  local why
  if ! ls "$1" >/dev/null 2>"$WORK/ls.err"; then
    why="$(deny_reason "$WORK/ls.err")"
    why="${why:-一覧できませんでした}"
    UNREADABLE_WHY="$why"
    printf '| %s | %s |\n' "$(cell "$1")" "$(cell "$why")" >>"$WORK/unreadable"
    log_error "読めなかった: ${1}: ${why}"
    return 1
  fi
  return 0
}

# 1つのリポジトリを巡回する。name は PATROL_ROOT からの相対パスである。
patrol_one() {
  name="$1"
  repo="$PATROL_ROOT/$name"
  total=$((total + 1))
  if ! inspect_repo "$name"; then
    printf '| %s | %s |\n' "$(cell "$name")" "$(cell "$FAIL_REASON")" >>"$WORK/failed"
    log_error "取得失敗: ${name}: ${FAIL_REASON}"
  fi
}

# 直下で .git を持つディレクトリをリポジトリとして数える。
# 直下で .git を持たないディレクトリは、その1段下で .git を持つディレクトリを数える（リポジトリの中には入らない）。
# シンボリックリンクは [ -d ] で辿り、実体がディレクトリであれば通常のディレクトリと同じに扱う。
total=0
root_unreadable=""
if check_readable_dir "$PATROL_ROOT"; then
  for path in "$PATROL_ROOT"/*; do
    [ -d "$path" ] || continue
    top="${path##*/}"
    if [ -e "$path/.git" ]; then
      patrol_one "$top"
      continue
    fi
    check_readable_dir "$path" || continue
    for sub in "$path"/*; do
      [ -d "$sub" ] || continue
      [ -e "$sub/.git" ] || continue
      patrol_one "$top/${sub##*/}"
    done
  done
else
  root_unreadable="$UNREADABLE_WHY"
fi

if [ -z "$root_unreadable" ] && [ "$total" -eq 0 ]; then
  log_warn "巡回の対象のリポジトリが0件です: ${PATROL_ROOT}"
fi

count_lines() {
  if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else printf '0'; fi
}

build_report() {
  printf '# リポジトリ巡回レポート\n\n'
  printf -- '- 作成日時: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -n "$root_unreadable" ]; then
    printf -- '- 対象: %s（読めなかった: %s）\n' "$PATROL_ROOT" "$root_unreadable"
  else
    printf -- '- 対象: %s（%s件）\n' "$PATROL_ROOT" "$total"
  fi
  if [ -z "$root_unreadable" ] && [ "$total" -eq 0 ]; then
    printf -- '- 警告: 対象のリポジトリが0件である。フォルダの指定と中身を確かめること。\n'
  fi
  if [ -s "$WORK/unreadable" ]; then
    printf -- '- 失敗: 一覧を読めなかったフォルダがある（%s件）。下の「読めなかったフォルダ」を確かめること。\n' "$(count_lines "$WORK/unreadable")"
  fi
  printf -- '- 内訳: 対応が要るもの %s件、片付けの候補 %s件、問題なし %s件、取得失敗 %s件\n' \
    "$(count_lines "$WORK/action")" "$(count_lines "$WORK/cleanup")" "$(count_lines "$WORK/ok")" "$(count_lines "$WORK/failed")"
  printf -- '- 追跡ブランチは取得していない（git fetch を行わない）。ahead/behind と未push の判定は、最終取得の時点の参照に基づく。\n\n'

  printf '## 対応が要るもの\n\n'
  if [ -s "$WORK/action" ]; then
    printf '| リポジトリ | ブランチ | staged | unstaged | untracked | stash | 上流との差 | 未pushのブランチ | 最終取得 |\n'
    printf '| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
    cat "$WORK/action"
  else
    printf '該当なし\n'
  fi

  printf '\n## 片付けの候補\n\n'
  if [ -s "$WORK/cleanup" ]; then
    printf '既定ブランチへマージ済みのローカルブランチ（現在のブランチを除く）。\n\n'
    printf '| リポジトリ | 既定ブランチ | マージ済みのブランチ |\n'
    printf '| --- | --- | --- |\n'
    cat "$WORK/cleanup"
  else
    printf '該当なし\n'
  fi

  if [ -s "$WORK/unreadable" ]; then
    printf '\n## 読めなかったフォルダ\n\n'
    printf '| フォルダ | 理由 |\n'
    printf '| --- | --- |\n'
    cat "$WORK/unreadable"
  fi

  printf '\n## 取得失敗\n\n'
  if [ -s "$WORK/failed" ]; then
    printf '| リポジトリ | 理由 |\n'
    printf '| --- | --- |\n'
    cat "$WORK/failed"
  else
    printf '該当なし\n'
  fi

  printf '\n## 問題なし\n\n'
  if [ -s "$WORK/ok" ]; then
    cat "$WORK/ok"
  else
    printf '該当なし\n'
  fi
}

failed=0
[ -s "$WORK/unreadable" ] && failed=1

if [ "$to_stdout" -eq 1 ]; then
  build_report
  exit "$failed"
fi

mkdir -p "$REPORTS_ROOT/$JOB_NAME" || exit 1
report="$(next_report_path "$REPORTS_ROOT/$JOB_NAME")"
if ! build_report >"$report"; then
  log_error "レポートを書けませんでした: ${report}"
  exit 1
fi
log_info "レポートを書きました: ${report}（対象 ${total}件）"
if [ "$failed" -eq 1 ]; then
  log_error "一覧を読めなかったフォルダがあります。レポートの「読めなかったフォルダ」を確かめてください"
  exit 1
fi
exit 0
