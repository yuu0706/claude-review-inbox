#!/bin/bash
# report-inbox 共通定義。各スクリプトから source して使う。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。
# unread.sh が SessionStart フックで毎回動くため、外部コマンドの起動を最小限にする。

REPORTS_ROOT="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORTS_ROOT="${REPORTS_ROOT%/}"
INBOX_STATE_DIR="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
INBOX_STATE_DIR="${INBOX_STATE_DIR%/}/report-inbox"
READ_FILE="$INBOX_STATE_DIR/read.txt"
NL=$'\n'
TAB=$'\t'
# 否認・訂正リストと旧来の案のファイルの置き場所は、結果のジョブとして数えない。
PROPOSALS_JOB="proposals"
PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-$REPORTS_ROOT/$PROPOSALS_JOB}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"

# REPORTS_ROOT の実体の絶対パスを REAL_ROOT に入れる。無ければ 1 を返す。
resolve_root() {
  [ -d "$REPORTS_ROOT" ] || return 1
  REAL_ROOT="$(cd -P "$REPORTS_ROOT" 2>/dev/null && pwd -P)" || return 1
  [ -n "$REAL_ROOT" ]
}

# ファイル名がレポートの形（<YYYY-MM-DD>.md または <YYYY-MM-DD>-<連番>.md）なら 0 を返す。
is_report_name() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md) return 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md)
      case "${1:11}" in
        *[!0-9]*.md|.md) return 1 ;;
      esac
      return 0 ;;
  esac
  return 1
}

# 既読の記録を読めるかを確かめる。記録はあるが読めなければ 1 を返す。記録が無いのは読める扱いとする。
# 中身は読み込まない。多数のレポートの既読の判定は list_reports_marked で行う。
check_read_file() {
  local dir="${READ_FILE%/*}"
  # 状態ディレクトリを辿れなければ、記録の有無を判断できないので失敗とする。
  if [ -d "$dir" ] && [ ! -x "$dir" ]; then
    return 1
  fi
  [ -e "$READ_FILE" ] || return 0
  [ -r "$READ_FILE" ]
}

# 既読の記録を、改行で囲んだ1つの文字列として READ_SET に入れる。記録はあるが読めなければ 1 を返す。
# 記録が多いと読み込みに時間がかかるため、unread.sh と list.sh では使わない。
load_read_set() {
  READ_SET="$NL"
  local line dir="${READ_FILE%/*}"
  # 状態ディレクトリを辿れなければ、記録の有無を判断できないので失敗とする。
  if [ -d "$dir" ] && [ ! -x "$dir" ]; then
    return 1
  fi
  [ -e "$READ_FILE" ] || return 0
  [ -r "$READ_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && READ_SET="$READ_SET$line$NL"
  done <"$READ_FILE" || return 1
  return 0
}

# READ_SET に引数のパスがあれば 0 を返す。1回の照合で既読の件数に比例する時間がかかるため、
# 多数のレポートを判定するときは list_reports_marked を使う。
is_read() {
  case "$READ_SET" in
    *"$NL$1$NL"*) return 0 ;;
  esac
  return 1
}

# レポートを「日付<TAB>連番<TAB>ジョブ名<TAB>パス」の形で1行に1件ずつ出力する。順序は問わない。
# 各ジョブのディレクトリ直下だけを見る。.snapshots・.staging などの下位ディレクトリは数えない。
# ドット始まりのディレクトリは glob に一致しないため、ジョブとしても数えない。
# 否認・訂正リストの置き場所（PROPOSALS_JOB）は結果のジョブではないため数えない。
list_reports() {
  local dir job f base seq
  for dir in "$REAL_ROOT"/*/; do
    [ -d "$dir" ] || continue
    job="${dir%/}"
    job="${job##*/}"
    [ "$job" = "$PROPOSALS_JOB" ] && continue
    for f in "$dir"*.md; do
      [ -f "$f" ] || continue
      base="${f##*/}"
      is_report_name "$base" || continue
      seq="${base:11}"
      seq="${seq%.md}"
      printf '%s\t%s\t%s\t%s\n' "${base:0:10}" "${seq:-1}" "$job" "$REAL_ROOT/$job/$base"
    done
  done
  return 0
}

# list_reports の各行の末尾に、既読なら 1、未読なら 0 の列を足して出力する。
# 既読の記録を awk で1回だけ読み込んで照合するため、件数が増えても1件あたりの時間は増えない。
# 事前に load_read_set で記録を読めることを確かめておく。
list_reports_marked() {
  # 既読の記録が空でも照合を誤らないよう、NR == FNR ではなく BEGIN の getline で読む。
  local src="$READ_FILE"
  [ -f "$src" ] || src=/dev/null
  list_reports | awk -F '\t' -v src="$src" '
    BEGIN { while ((getline line < src) > 0) if (line != "") seen[line] = 1 }
    { print $0 "\t" (($4 in seen) ? 1 : 0) }'
}

# 引数のパスを絶対パスへ直し、レポートであれば NORM_PATH に入れて 0 を返す。
normalize_report_path() {
  local p="$1" dir base rel
  NORM_PATH=""
  [ -f "$p" ] || return 1
  case "$p" in
    */*) dir="${p%/*}" ;;
    *) dir="." ;;
  esac
  base="${p##*/}"
  dir="$(cd -P "${dir:-/}" 2>/dev/null && pwd -P)" || return 1
  case "$dir/" in
    "$REAL_ROOT"/*/) ;;
    *) return 1 ;;
  esac
  rel="${dir#$REAL_ROOT/}"
  case "$rel" in
    */*|''|.*) return 1 ;;
  esac
  is_report_name "$base" || return 1
  NORM_PATH="$dir/$base"
  return 0
}

# ---- 定期実行の失敗の知らせ ----
# 対象のジョブと、各ジョブの状態ディレクトリ。各ジョブのスクリプトと同じ環境変数で差し替えられる。
FAIL_JOBS="feedback-mining memory-audit repo-patrol skill-audit secret-patrol weakness-review"
FAIL_STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
FAIL_STATE_BASE="${FAIL_STATE_BASE%/}"
FAIL_SKILL_AUDIT_STATE="${SKILL_AUDIT_STATE:-$HOME/.local/state/skill-audit}"
FAIL_SKILL_AUDIT_STATE="${FAIL_SKILL_AUDIT_STATE%/}"
FAIL_READ_DIR="$INBOX_STATE_DIR/failure-read"
# 運用上は問題にしない ERROR。二重起動の拒否は各ジョブがログを開く前に出すため、標準エラーにだけ現れる。
FAIL_IGNORE_PATTERN="別の実行が進行中です"

is_fail_job() {
  case " $FAIL_JOBS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# ジョブの状態ディレクトリを JOB_STATE に入れる。
job_state_dir() {
  if [ "$1" = "skill-audit" ]; then
    JOB_STATE="$FAIL_SKILL_AUDIT_STATE"
  else
    JOB_STATE="$FAIL_STATE_BASE/$1"
  fi
}

# 既読にした時刻（YYYY-MM-DD HH:MM:SS）を MARK_TIME に、その時点の標準エラーの行数を MARK_LINES に入れる。
# 記録が無ければ空と 0 にする。
load_failure_mark() {
  MARK_FILE="$FAIL_READ_DIR/$1"
  MARK_TIME=""
  MARK_LINES=0
  [ -f "$MARK_FILE" ] || return 0
  { IFS= read -r MARK_TIME; IFS= read -r MARK_LINES; } <"$MARK_FILE" || true
  case "$MARK_LINES" in
    ''|*[!0-9]*) MARK_LINES=0 ;;
  esac
  return 0
}

# 1つのファイルを走査し、失敗に当たる行を数える。
# 引数: ファイル、種別（log または stderr）、読み飛ばす行数、既読の時刻
# 結果: SRC_COUNT（件数）、SRC_TIME（最も新しい行の時刻。YYYY-MM-DD HH:MM）、SRC_LINES（先頭3行。改行区切り）
scan_failure_file() {
  local file="$1" kind="$2" skip="$3" since="$4" line n=0
  SRC_COUNT=0; SRC_TIME=""; SRC_LINES=""
  [ -f "$file" ] && [ -r "$file" ] || return 0
  # 大きなファイルを bash で1行ずつ読むと遅いため、awk で1回だけ読む。
  # awk の出力は1行目が件数、2行目が最も新しい時刻、3行目以降が先頭3行である。
  while IFS= read -r line; do
    n=$((n + 1))
    case "$n" in
      1) SRC_COUNT="$line" ;;
      2) SRC_TIME="$line" ;;
      *) SRC_LINES="${SRC_LINES}${line}${NL}" ;;
    esac
  done < <(awk -v kind="$kind" -v skip="$skip" -v since="$since" -v ignore="$FAIL_IGNORE_PATTERN" '
    NR <= skip || $0 == "" { next }
    index($0, ignore) > 0 { next }
    {
      ts = ""
      if ($0 ~ /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] ERROR: /) {
        ts = substr($0, 2, 19)
      } else if (kind == "log") {
        # ログでは ERROR の行だけを数える。標準エラーでは空でない行をすべて数える。
        next
      }
      # 既読にした時刻以前の ERROR は数えない。時刻の無い行は読み飛ばしの行数で判断する。
      if (ts != "" && since != "" && ts <= since) next
      count++
      if (count <= 3) first[count] = $0
      if (ts != "" && substr(ts, 1, 16) > latest) latest = substr(ts, 1, 16)
    }
    END {
      print count + 0
      print latest
      for (i = 1; i <= count && i <= 3; i++) print first[i]
    }' "$file" 2>/dev/null)
  case "$SRC_COUNT" in
    ''|*[!0-9]*) SRC_COUNT=0 ;;
  esac
  # 時刻の書かれた行が無ければ、ファイルの更新時刻で代える。
  if [ "$SRC_COUNT" -gt 0 ] && [ -z "$SRC_TIME" ]; then
    SRC_TIME="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$file" 2>/dev/null)"
  fi
  return 0
}

# ファイルの行数を出力する。末尾に改行の無い行も1行と数える（tail -n +N と数え方を揃える）。
count_file_lines() {
  awk 'END { print NR }' "$1" 2>/dev/null || printf '0\n'
}

# ジョブの失敗を調べる。失敗があれば 0 を返し、次を設定する。
#   FAIL_TIME（最も新しい時刻）、FAIL_LOG と FAIL_LOG_LINES（ログ側）、FAIL_STDERR と FAIL_STDERR_LINES（標準エラー側）
# 既読の印より古いファイルは開かない（unread.sh の速度のため）。
check_job_failure() {
  local job="$1" f newest=""
  FAIL_TIME=""; FAIL_LOG=""; FAIL_LOG_LINES=""; FAIL_STDERR=""; FAIL_STDERR_LINES=""
  job_state_dir "$job"
  load_failure_mark "$job"
  # ログの名前は開始時刻（YYYY-MM-DD-HHMMSS.log）なので、glob の並びの最後が最新である。
  for f in "$JOB_STATE"/logs/*.log; do
    [ -f "$f" ] && newest="$f"
  done
  if [ -n "$newest" ] && ! { [ -f "$MARK_FILE" ] && [ "$newest" -ot "$MARK_FILE" ]; }; then
    scan_failure_file "$newest" log 0 "$MARK_TIME"
    if [ "$SRC_COUNT" -gt 0 ]; then
      FAIL_LOG="$newest"; FAIL_LOG_LINES="$SRC_LINES"; FAIL_TIME="$SRC_TIME"
    fi
  fi
  f="$JOB_STATE/launchd.stderr.log"
  if [ -s "$f" ] && ! { [ -f "$MARK_FILE" ] && [ "$f" -ot "$MARK_FILE" ]; }; then
    local skip="$MARK_LINES"
    # 標準エラーが切り詰められていれば、先頭から数え直す。
    if [ "$skip" -gt 0 ] && [ "$(count_file_lines "$f")" -lt "$skip" ]; then
      skip=0
    fi
    scan_failure_file "$f" stderr "$skip" "$MARK_TIME"
    if [ "$SRC_COUNT" -gt 0 ]; then
      FAIL_STDERR="$f"; FAIL_STDERR_LINES="$SRC_LINES"
      [[ "$SRC_TIME" > "$FAIL_TIME" ]] && FAIL_TIME="$SRC_TIME"
    fi
  fi
  [ -n "$FAIL_LOG" ] || [ -n "$FAIL_STDERR" ]
}

# ジョブの失敗の知らせを既読にする。現在の時刻と標準エラーの行数を記録する。
mark_failure_read() {
  local job="$1" f n=0 now
  job_state_dir "$job"
  f="$JOB_STATE/launchd.stderr.log"
  [ -f "$f" ] && n="$(count_file_lines "$f")"
  now="$(date '+%Y-%m-%d %H:%M:%S')" || return 1
  mkdir -p "$FAIL_READ_DIR" || return 1
  printf '%s\n%s\n' "$now" "$n" >"$FAIL_READ_DIR/$job.tmp" && mv -f "$FAIL_READ_DIR/$job.tmp" "$FAIL_READ_DIR/$job"
}

# ---- 直したいこと（Skill change-review） ----
list_pending_changes() {
  local c
  for c in "${CHANGE_REVIEW_SCRIPTS:-}" "${SCRIPT_DIR:-.}/../../change-review/scripts" "$HOME/.claude/skills/change-review/scripts"; do
    if [ -n "$c" ] && [ -f "$c/changes-log.py" ]; then
      python3 -B "$c/changes-log.py" list
      return
    fi
  done
  return 0
}
