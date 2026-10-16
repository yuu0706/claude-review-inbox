#!/bin/bash
# feedback-mining を非対話で起動する。launchd から週1回呼ばれる。
# 前回の実行より後に更新された会話の履歴（jsonl）を選び、利用者本人の発言だけを取り出したファイル（extract-user.py）の
# 一覧を claude（CLAUDE_LAUNCHER）へ渡す。claude には元の jsonl を読ませない。
# 使い方: run.sh [--dry-run]
#   --dry-run  起動せず、組み立てたコマンドを標準出力へ表示する。last-run は更新しない。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。
set -u

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
unset CLAUDE_CONFIG_DIR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
JOB_NAME="feedback-mining"
REPORTS_ROOT="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORTS_ROOT="${REPORTS_ROOT%/}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
STATE_DIR="${STATE_BASE%/}/$JOB_NAME"
REPORT_DIR="$REPORTS_ROOT/$JOB_NAME"
FIRST_RUN_DAYS=7
# 利用者の環境だけの決まりを書く上書きファイル。SKILL.md より優先して読ませる。
OVERRIDE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-skills/$JOB_NAME.local.md"

# 定期実行の共通の設定（jobs.conf）。環境変数が設定ファイルより優先する。値の先頭の ~ だけを展開し、eval は使わない。
JOBS_CONF="${CLAUDE_REVIEW_JOBS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/jobs.conf}"
jobs_conf() {
  local v
  [ -f "$JOBS_CONF" ] || return 0
  v="$(sed -n "s/^$1=//p" "$JOBS_CONF" | tail -n 1)"
  case "$v" in '~'*) v="$HOME${v#\~}" ;; esac
  printf '%s' "$v"
}
# 起動するコマンド。空白で区切った語の {job} はジョブ名に置き換える（例: 別アカウントで起動するラッパー {job}）。
[ -n "${CLAUDE_LAUNCHER:-}" ] || CLAUDE_LAUNCHER="$(jobs_conf CLAUDE_LAUNCHER)"
[ -n "$CLAUDE_LAUNCHER" ] || CLAUDE_LAUNCHER=claude
# Claude の設定ディレクトリの一覧（コロン区切り）。2つ目の設定ディレクトリを使う場合はここに足す。存在するものだけを使う。
[ -n "${CLAUDE_REVIEW_CONFIG_DIRS:-}" ] || CLAUDE_REVIEW_CONFIG_DIRS="$(jobs_conf CLAUDE_REVIEW_CONFIG_DIRS)"
[ -n "$CLAUDE_REVIEW_CONFIG_DIRS" ] || CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude"
# 読み取りを拒否する追加の場所（コロン区切り）。クラウドストレージの同期フォルダ等を指定する。
[ -n "${CLAUDE_REVIEW_DENY_READ:-}" ] || CLAUDE_REVIEW_DENY_READ="$(jobs_conf CLAUDE_REVIEW_DENY_READ)"
split_dirs() {
  local IFS=: d
  for d in $1; do
    case "$d" in '~'*) d="$HOME${d#\~}" ;; esac
    [ -n "$d" ] && printf '%s\n' "${d%/}"
  done
}
config_dirs=()
while IFS= read -r d; do [ -d "$d" ] && config_dirs+=("$d"); done < <(split_dirs "$CLAUDE_REVIEW_CONFIG_DIRS")
deny_read_extra=()
while IFS= read -r d; do deny_read_extra+=("$d"); done < <(split_dirs "${CLAUDE_REVIEW_DENY_READ:-}")
skill_dirs=()
default_sources=""
for c in ${config_dirs[@]+"${config_dirs[@]}"}; do
  skill_dirs+=("$c/skills")
  default_sources="${default_sources:+$default_sources:}$c/projects"
done
# 会話の履歴を探すディレクトリ。コロン区切り。存在しないものは飛ばす。
SOURCES="${FEEDBACK_MINING_SOURCES:-$default_sources}"
# 承認待ちの置き場所・否認リスト・判断の台帳（claude-review-inbox）。
PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-$REPORTS_ROOT/proposals}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"
REJECTIONS="$PROPOSALS_DIR/rejections.md"
LEDGER_DIR="${CLAUDE_REVIEW_STATE:-$HOME/.local/state/claude-review-inbox}"
LEDGER_DIR="${LEDGER_DIR%/}"
LOG_KEEP=30

log_error() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_info() {
  printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    *) log_error "不明な引数です: ${arg}"; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR/logs" "$REPORT_DIR" || exit 1
REPORT_DIR="$(cd -P "$REPORT_DIR" && pwd -P)" || exit 1

LOCK_DIR="$STATE_DIR/lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_error "別の実行が進行中です（${LOCK_DIR} が存在します）"
  exit 1
fi
STAMP="$STATE_DIR/run-started.$$"
trap 'rm -f "$STAMP"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
# 実行の開始時刻を記録する。成功したときにこのファイルを last-run にする。
# 実行中に更新された会話は、次回の対象に入る。
touch "$STAMP" || exit 1

if [ "$dry_run" -eq 0 ]; then
  LOG_FILE="$STATE_DIR/logs/$(date '+%Y-%m-%d-%H%M%S').log"
  exec >>"$LOG_FILE" 2>&1
  # 古いログを LOG_KEEP 件まで減らす。削除してよいのはログだけである。
  ls -1t "$STATE_DIR/logs/"*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)) | while IFS= read -r old; do
    rm -f -- "$old"
  done
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

# claude -p で起動したセッションであれば 0 を返す。
# 各行の entrypoint のうち最初に現れる値が sdk-cli のものを -p のセッションとみなす。
# 対話の CLI は cli、VS Code は claude-vscode、デスクトップアプリは claude-desktop になる。
# entrypoint を持たないファイルは除外しない。
is_print_session() {
  local ep
  ep="$(grep -m1 -o '"entrypoint":"[^"]*"' "$1" 2>/dev/null)"
  [ "$ep" = '"entrypoint":"sdk-cli"' ]
}

# 対象の jsonl を1行に1件ずつ出力する。subagents 配下も含める。
list_inputs() {
  local src f
  local IFS=':'
  for src in $SOURCES; do
    [ -d "$src" ] || continue
    if [ -f "$STATE_DIR/last-run" ]; then
      find "$src" -type f -name '*.jsonl' -newer "$STATE_DIR/last-run"
    else
      find "$src" -type f -name '*.jsonl' -mtime "-$FIRST_RUN_DAYS"
    fi
  done | LC_ALL=C sort | while IFS= read -r f; do
    is_print_session "$f" && continue
    printf '%s\n' "$f"
  done
}

ts="$(date '+%Y-%m-%d-%H%M%S')"
inputs="$STATE_DIR/inputs-$ts.txt"
if ! list_inputs >"$inputs"; then
  log_error "対象の会話の一覧を作れませんでした: ${inputs}"
  exit 1
fi
count="$(wc -l <"$inputs" | tr -d ' ')"
if [ -f "$STATE_DIR/last-run" ]; then
  since="前回の実行（$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$STATE_DIR/last-run")）以降"
else
  since="初回のため過去${FIRST_RUN_DAYS}日"
fi
log_info "対象の会話: ${count}件（${since}）。一覧: ${inputs}"

report="$(next_report_path "$REPORT_DIR")"

if [ "$count" -eq 0 ]; then
  if [ "$dry_run" -eq 1 ]; then
    log_info "対象の会話なし。起動しません"
    exit 0
  fi
  printf '# 指摘の収集レポート\n\n対象の会話なし\n' >"$report" || exit 1
  mv -f "$STAMP" "$STATE_DIR/last-run"
  log_info "対象の会話なし。レポートを書きました: ${report}"
  exit 0
fi

# 検問所: 元の jsonl を claude に読ませず、利用者本人の発言だけを取り出したファイルを渡す（extract-user.py）。
# ツールの結果・フックの出力・貼り付けた文章など、利用者以外が書いた文章を指示として読ませないためである。
EXTRACT_DIR="$STATE_DIR/extracted-$ts"
extracted="$STATE_DIR/extracted-$ts.txt"
EXTRACT_KEEP=10
if [ "$dry_run" -eq 0 ]; then
  if ! python3 -B "$SCRIPT_DIR/extract-user.py" "$inputs" "$EXTRACT_DIR" >"$extracted"; then
    log_error "利用者の発言を取り出せませんでした: ${inputs}。last-run は更新しません"
    exit 1
  fi
  # 古い取り出し結果を EXTRACT_KEEP 回分まで減らす。削除してよいのは取り出し結果だけである。
  ls -1d "$STATE_DIR/extracted-"*.txt 2>/dev/null | LC_ALL=C sort -r | tail -n +$((EXTRACT_KEEP + 1)) | while IFS= read -r old; do
    rm -rf -- "${old%.txt}" "$old"
  done
  n_extracted="$(grep -c . "$extracted" | tr -d ' ')"
  log_info "利用者の発言を取り出しました: ${n_extracted}件（${EXTRACT_DIR}）"
  if [ "$n_extracted" -eq 0 ]; then
    printf '# 指摘の収集レポート\n\n対象の会話 %s件に、利用者の発言はありませんでした\n' "$count" >"$report" || exit 1
    mv -f "$STAMP" "$STATE_DIR/last-run"
    log_info "利用者の発言なし。レポートを書きました: ${report}"
    exit 0
  fi
fi

PROMPT="Skill feedback-mining を自動モードで実行する。対象の会話から利用者本人の発言だけを取り出したファイルの一覧は ${extracted}、レポートの出力先は ${report}。元の会話（jsonl）は読まない（権限で拒否している）。取り出したファイルの見出しにある元の会話のパスを、根拠として書く。否認リストは ${REJECTIONS} にある。決まりの案を作る前に読み、否認リストと同じ対象・同じ趣旨の案は作らない。利用者の環境だけの決まりは ${OVERRIDE_FILE} にある（無ければ飛ばす）。"

# スキルの置き場所の直下にあるリンクの先の実体を求める共通の処理（Skill change-review の link-scopes.sh）を読み込む。
# claude -p の権限は実体のパスで判定されるため、リンクの先の実体を許可・拒否の規則に足す。
# 書き換えを拒否する規則（南京錠）もここから作るため、読み込めなければ起動しない。
for lsc in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" \
  ${skill_dirs[@]+"${skill_dirs[@]/%//change-review/scripts}"}; do
  [ -n "$lsc" ] && [ -f "$lsc/link-scopes.sh" ] && . "$lsc/link-scopes.sh" && break
done
if ! type guard_deny_rules >/dev/null 2>&1; then
  log_error "Skill change-review の link-scopes.sh を読み込めません。書き換えを拒否する規則を作れないため、収集を起動しません"
  exit 1
fi
link_reals=()
while IFS= read -r lr; do [ -n "$lr" ] && link_reals+=("$lr"); done < <(skill_link_reals ${skill_dirs[@]+"${skill_dirs[@]}"})

# 読んでよい範囲を設定ディレクトリ（スキル・メモリ・会話の履歴）・結果の置き場所に限る。範囲を付けない Read・Glob・Grep と、
# 任意のパスを読める Bash（ls・grep・jq 等）は許可しない。ホームの下の同期フォルダ等を検索すると、
# macOS がアクセス許可のダイアログを出すためである。
read_scopes=(${config_dirs[@]+"${config_dirs[@]}"} "$HOME/.agents" "$REPORTS_ROOT" "${STATE_BASE%/}"
  "$PROPOSALS_DIR")
allowed=(Skill)
for d in "${read_scopes[@]}"; do allowed+=("Read(/$d/**)"); done
allowed+=("Read(/$OVERRIDE_FILE)")
# 反映済みの指摘の日付を突き合わせるため、skill-audit の変更の記録（スキル置き場の外）だけを読ませる。
SKILL_AUDIT_HISTORY="${SKILL_AUDIT_STATE:-$HOME/.local/state/skill-audit}"
allowed+=("Read(/${SKILL_AUDIT_HISTORY%/}/history.md)")
for lr in ${link_reals[@]+"${link_reals[@]}"}; do allowed+=("Read(/$lr/**)"); done
allowed+=("Edit(/$REPORT_DIR/**)")
disallowed=("Read(/$HOME/Library/CloudStorage/**)")
for d in ${deny_read_extra[@]+"${deny_read_extra[@]}"}; do disallowed+=("Read(/$d/**)"); done
for c in ${config_dirs[@]+"${config_dirs[@]}"}; do disallowed+=("Edit(/$c/**)"); done
disallowed+=("Edit(/$HOME/Documents/**)" "Edit(/$HOME/.agents/**)" "Edit(/$PROPOSALS_DIR/**)" "Edit(/$LEDGER_DIR/**)")
# スキルのリンクの先の実体も書き換えさせない。
for lr in ${link_reals[@]+"${link_reals[@]}"}; do disallowed+=("Edit(/$lr/**)"); done
# CLAUDE.md・settings.json は別の設定ディレクトリへのリンクのことがある。実体のパスでも拒否する。
deny_files=()
for c in ${config_dirs[@]+"${config_dirs[@]}"}; do deny_files+=("$c/CLAUDE.md" "$c/settings.json"); done
for df in ${deny_files[@]+"${deny_files[@]}"} "$PROPOSALS_DIR" "$LEDGER_DIR"; do
  while IFS= read -r dp; do
    if [ -d "$dp" ]; then disallowed+=("Edit(/$dp/**)"); else disallowed+=("Edit(/$dp)"); fi
  done < <(path_and_real "$df" | tail -n +2)
done
# 南京錠: 安全のための規則のスキル・フックと定期実行のスクリプト・設定ファイル・変更の台帳を、表記と実体の両方で拒否する。
while IFS= read -r gr; do disallowed+=("$gr"); done < <(guard_deny_rules ${config_dirs[@]+"${config_dirs[@]}"} -- \
  ${skill_dirs[@]+"${skill_dirs[@]}"})
# 検問所: 元の会話の jsonl は、表記と実体の両方で読ませない（取り出したファイルだけを読ませる）。
src_dirs=()
for c in ${config_dirs[@]+"${config_dirs[@]}"}; do src_dirs+=("$c/projects"); done
while IFS= read -r d; do [ -n "$d" ] && src_dirs+=("$d"); done < <(printf '%s\n' "$SOURCES" | tr ':' '\n')
seen_src=" "
for d in ${src_dirs[@]+"${src_dirs[@]}"}; do
  while IFS= read -r dp; do
    case "$seen_src" in *" $dp "*) continue ;; esac
    seen_src="$seen_src$dp "
    disallowed+=("Read(/${dp%/}/**/*.jsonl)")
  done < <(path_and_real "${d%/}")
done

# 起動に使うコマンド（CLAUDE_LAUNCHER）。語の {job} はジョブ名に置き換える。
launcher=()
read -r -a launcher_words <<<"$CLAUDE_LAUNCHER"
for w in "${launcher_words[@]}"; do
  [ "$w" = "{job}" ] && w="$JOB_NAME"
  launcher+=("$w")
done
log_info "起動に使うコマンド: ${launcher[*]}"
# --permission-mode default: settings.json の defaultMode（acceptEdits 等）で作業場所の中の編集が許可なしに通らないようにし、
# 許可を --allowedTools だけで決める。
cmd=("${launcher[@]}" -p "$PROMPT" --model opus --effort low --permission-mode default
  --allowedTools "${allowed[@]}" --disallowedTools "${disallowed[@]}")

# コマンドを単一引用符で囲んだ形で表示する。printf %q は bash 3.2 でマルチバイト文字を壊すため使わない。
print_command() {
  local a sq="'\\''"
  printf "cd '%s' &&" "${REPORT_DIR//\'/$sq}"
  for a in "${cmd[@]}"; do
    printf " '%s'" "${a//\'/$sq}"
  done
  printf '\n'
}

if [ "$dry_run" -eq 1 ]; then
  print_command
  exit 0
fi

log_info "収集を起動します"
print_command
(cd "$REPORT_DIR" && "${cmd[@]}")
rc=$?

if [ "$rc" -ne 0 ]; then
  log_error "収集が異常終了しました（終了コード ${rc}）。last-run は更新しません"
  exit "$rc"
fi
if [ ! -s "$report" ]; then
  log_error "レポートが作られていません: ${report}。last-run は更新しません"
  exit 1
fi

mv -f "$STAMP" "$STATE_DIR/last-run"
log_info "収集が完了しました。レポート: ${report}。last-run を更新しました"
exit 0
