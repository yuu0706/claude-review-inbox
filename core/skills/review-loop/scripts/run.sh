#!/bin/bash
# review-loop（週1回の棚卸し）を非対話で起動する。install.sh が登録した launchd から呼ばれる。
# 自作のスキルとメモリを複製してから claude -p を起動する。claude には直した版を作業用のフォルダへ書かせ、
# 正常終了した場合だけ、シェルがファイルごとに差分を取る。既存の行を変えない・消さない変更（diff の - 行が無いもの）は
# 元の場所へ書き戻し、それ以外の修正・新しいファイル・削除の候補は Skill change-review の承認待ちの案にする。
# 修正・削除の案には、claude が候補ごとに作った「消える記述の行き先」の表と、移し先への追加の差分を入れる（Skill change-review「2.2」）。
# メモリの削除の案には、そのメモリを指す索引（MEMORY.md）の行の削除も入れ、索引だけの案を別に作らない。
# claude には元のスキル・メモリ・案・台帳を直接書かせない（--allowedTools / --disallowedTools で制限する）。
# 使い方: run.sh [--dry-run] [--force]
#   --dry-run  複製も起動もせず、対象と組み立てたコマンドを標準出力へ表示する。
#   --force    前回から対象が変わっていなくても起動する。
# 環境変数:
#   CLAUDE_REVIEW_LOOP_MODEL   claude に渡す --model（未指定なら付けない）
#   CLAUDE_REVIEW_LOOP_EFFORT  claude に渡す --effort（未指定なら付けない）
#   CLAUDE_REPORTS_ROOT        結果の置き場所の親（既定 ~/claude-reports）
#   CLAUDE_REVIEW_PROPOSALS    承認待ちの置き場所（既定 <CLAUDE_REPORTS_ROOT>/proposals）
#   CLAUDE_REVIEW_STATE        状態の置き場所（既定 ~/.local/state/claude-review-inbox）
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。
set -u

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
unset CLAUDE_CONFIG_DIR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SELF_REPO_SKILLS="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
JOB_NAME="review-loop"
MAX_CHANGES=5
HISTORY_DAYS=7
LOG_KEEP=30
RUN_KEEP=10
REPORTS_ROOT="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORTS_ROOT="${REPORTS_ROOT%/}"
REPORT_DIR="$REPORTS_ROOT/$JOB_NAME"
PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-$REPORTS_ROOT/proposals}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"
REJECTIONS="$PROPOSALS_DIR/rejections.md"
LEDGER_DIR="${CLAUDE_REVIEW_STATE:-$HOME/.local/state/claude-review-inbox}"
LEDGER_DIR="${LEDGER_DIR%/}"
STATE_DIR="$LEDGER_DIR/$JOB_NAME"

log_error() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info() { printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

dry_run=0
force=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --force) force=1 ;;
    *) log_error "不明な引数です: ${arg}"; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR/logs" "$STATE_DIR/runs" "$REPORT_DIR" || exit 1
STATE_DIR="$(cd -P "$STATE_DIR" && pwd -P)" || exit 1
REPORT_DIR="$(cd -P "$REPORT_DIR" && pwd -P)" || exit 1

LOCK_DIR="$STATE_DIR/lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_error "別の実行が進行中です（${LOCK_DIR} が存在します）"
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

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
  local day n
  day="$(date '+%Y-%m-%d')"
  if [ ! -e "$REPORT_DIR/$day.md" ]; then
    printf '%s\n' "$REPORT_DIR/$day.md"
    return 0
  fi
  n=2
  while [ -e "$REPORT_DIR/$day-$n.md" ]; do n=$((n + 1)); done
  printf '%s\n' "$REPORT_DIR/$day-$n.md"
}

# 設定ディレクトリ: ~/.claude と、存在すれば ~/.claude2。
config_dirs=("$HOME/.claude")
[ -d "$HOME/.claude2" ] && config_dirs+=("$HOME/.claude2")

# 対象を1行に1件ずつ出す。スキルは自作のもの（リンクでない・.trash でない・本リポジトリの core でない・SKILL.md がある）、
# メモリは projects/*/memory（リンクでない）。実体のパスで重複を除く。
list_targets() {
  local c d e real
  for c in "${config_dirs[@]}"; do
    d="$c/skills"
    if [ -d "$d" ]; then
      for e in "$d"/*; do
        [ -d "$e" ] || continue
        [ -L "$e" ] && continue
        [ -f "$e/SKILL.md" ] || continue
        real="$(cd -P "$e" && pwd -P)" || continue
        case "$real" in "$SELF_REPO_SKILLS"/*) continue ;; esac
        case "${real##*/}" in .trash) continue ;; esac
        printf '%s\n' "$real"
      done
    fi
    for e in "$c"/projects/*/memory; do
      [ -d "$e" ] || continue
      [ -L "$e" ] && continue
      real="$(cd -P "$e" && pwd -P)" || continue
      printf '%s\n' "$real"
    done
  done | LC_ALL=C sort -u
}

targets=()
while IFS= read -r t; do targets+=("$t"); done < <(list_targets)
if [ "${#targets[@]}" -eq 0 ]; then
  log_info "対象のスキルとメモリがありません。起動しません"
  exit 0
fi
log_info "対象: ${#targets[@]}件"

# 対象の中身の指紋。前回と同じなら起動しない。
targets_hash() {
  local t
  for t in "${targets[@]}"; do
    printf 'T %s\n' "$t"
    (cd "$t" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$(shasum -a 256 <"$f" | cut -d' ' -f1)" "$f"
    done)
  done | shasum -a 256 | cut -d' ' -f1
}
cur_hash="$(targets_hash)"
last_hash="$(cat "$STATE_DIR/last-hash" 2>/dev/null || true)"
if [ "$force" -eq 0 ] && [ "$cur_hash" = "$last_hash" ]; then
  log_info "前回から対象が変わっていません。起動しません（--force で起動できます）"
  exit 0
fi

ts="$(date '+%Y-%m-%d-%H%M%S')"
run_dir="$STATE_DIR/runs/$ts"
# 同じ秒の2回目以降は -2、-3 と連番にし、前の実行の作業用のフォルダを使い回さない。
n=2
while [ -e "$run_dir" ]; do run_dir="$STATE_DIR/runs/$ts-$n"; n=$((n + 1)); done
snap="$run_dir/before"
stage="$run_dir/stage"
report="$(next_report_path)"

# 作業用のフォルダの中での位置を求める。元の絶対パスの各要素のうち .claude で始まるもの（.claude・.claude2 等）は、
# 先頭のドットを外して写す。claude -p はパスに .claude の要素を含む場所への書き込みを拒否するためである。
stage_rel() {
  local rest="${1#/}" part out=""
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "$part" in
      .claude*) part="${part#.}" ;;
    esac
    out="$out/$part"
  done
  printf '%s\n' "$out"
}

staged=()
for t in "${targets[@]}"; do staged+=("$stage$(stage_rel "$t")"); done
mapping=""
i=0
while [ "$i" -lt "${#targets[@]}" ]; do
  mapping="${mapping}${mapping:+、}${targets[$i]} → ${staged[$i]}"
  i=$((i + 1))
done

history_globs=""
for c in "${config_dirs[@]}"; do history_globs="${history_globs}${history_globs:+、}$c/projects/*/*.jsonl"; done

# Skill change-review の scripts を探す。
find_change_review() {
  local c
  for c in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" \
    "$HOME/.claude/skills/change-review/scripts" "$HOME/.claude2/skills/change-review/scripts"; do
    if [ -n "$c" ] && [ -x "$c/new-proposal.sh" ] && [ -x "$c/diff-label.sh" ] && [ -x "$c/propose.sh" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}
CR_SCRIPTS="$(find_change_review)" || CR_SCRIPTS=""

# 修正・削除の候補ごとの「消える記述の行き先」の書き方（Skill change-review の destinations.sh が出す規則）。
DEST_RULE=""
[ -n "$CR_SCRIPTS" ] && DEST_RULE="$("$CR_SCRIPTS/destinations.sh" --print-rule "$stage/destinations")"

PROMPT="スキルとメモリの棚卸しを自動モードで行う（review-loop）。対象は ${targets[*]}。直す前の複製は ${snap} にある。
観点: (1) 古くなった情報・重複・矛盾、(2) 繰り返し同じ指示をしている作業（スキル化の候補）、(3) 既存のスキルで毎回補足している手順（スキルへの追記の候補）。
作業の履歴として、直近 ${HISTORY_DAYS} 日に更新された会話の履歴（${history_globs}）を読んでよい。
直した版は元のファイルを直接直さず、書き込み先 ${stage} へ書く（元の絶対パスの構造を保ち、.claude で始まる要素は先頭のドットを外して写す）。対象ごとの元の位置と書き込み先での位置は次のとおり: ${mapping}。新しいスキルを作る場合も、書き込み先の対応する位置に書く。
削除の候補は ${stage}/deletions.tsv に「元の絶対パス<TAB>理由」の形で1行1件書く。削除の候補のメモリを指す索引（MEMORY.md）の行は消さない（シェルが削除の案に含める）。
${DEST_RULE}
1回あたりの変更は ${MAX_CHANGES} 件までにする。
否認リストは ${REJECTIONS} にある。始める前に読み、否認リストと同じ対象・同じ趣旨の変更は作らない。
承認待ちの案は ${PROPOSALS_DIR}/*.md にある。frontmatter の status が pending の案と同じ変更は作らない。status が hold の案は、note の指摘を反映した改訂版なら作ってよい。
個人情報について、推測にもとづく変更を作らない。
最後に、要点を1〜3行で ${stage}/summary.md に書く。"

# スキルの置き場所の直下にあるリンクの先の実体を求める共通の処理（Skill change-review の link-scopes.sh）を読み込む。
# claude -p の権限は実体のパスで判定されるため、リンクの先の実体を許可・拒否の規則に足す。
# 読み込めない場合も動くよう、最小の処理で代える。
for lsc in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" "$SCRIPT_DIR/../../../../core/skills/change-review/scripts" \
  "$HOME/.claude/skills/change-review/scripts" "$HOME/.claude2/skills/change-review/scripts"; do
  [ -n "$lsc" ] && [ -f "$lsc/link-scopes.sh" ] && . "$lsc/link-scopes.sh" && break
done
if ! type skill_link_reals >/dev/null 2>&1; then
  path_and_real() {
    local r
    printf '%s\n' "$1"
    r="$( (cd -P "$1" 2>/dev/null && pwd -P) || readlink -f "$1" 2>/dev/null)"
    [ -n "$r" ] && [ "$r" != "$1" ] && printf '%s\n' "$r"
    return 0
  }
  skill_link_reals() {
    local e
    for e in "$HOME/.claude/skills" "$HOME/.claude2/skills" "$HOME/.claude/skills"/* "$HOME/.claude2/skills"/*; do
      [ -L "$e" ] && [ -d "$e" ] && (cd -P "$e" 2>/dev/null && pwd -P)
    done | awk '!seen[$0]++'
    return 0
  }
fi
link_reals=()
while IFS= read -r lr; do [ -n "$lr" ] && link_reals+=("$lr"); done < <(skill_link_reals)

# 読んでよい範囲を対象・会話の履歴・案の置き場所・複製に限る。Bash は許可しない。
read_scopes=("$PROPOSALS_DIR" "$snap" "$stage")
for c in "${config_dirs[@]}"; do read_scopes+=("$c/skills" "$c/projects"); done
for t in "${targets[@]}"; do read_scopes+=("$t"); done
allowed=()
for d in "${read_scopes[@]}"; do allowed+=("Read(/$d/**)"); done
for lr in ${link_reals[@]+"${link_reals[@]}"}; do allowed+=("Read(/$lr/**)"); done
allowed+=("Edit(/$stage/**)")
disallowed=(Bash "Edit(/$snap/**)" "Edit(/$PROPOSALS_DIR/**)" "Edit(/$LEDGER_DIR/$JOB_NAME/last-hash)"
  "Edit(/$REPORT_DIR/**)")
for c in "${config_dirs[@]}"; do disallowed+=("Edit(/$c/**)"); done
for t in "${targets[@]}"; do disallowed+=("Edit(/$t/**)"); done
# スキルのリンクの先の実体も書き換えさせない。
for lr in ${link_reals[@]+"${link_reals[@]}"}; do disallowed+=("Edit(/$lr/**)"); done
# CLAUDE.md・settings.json はリンクのことがある（~/.claude/CLAUDE.md -> ~/.claude2/CLAUDE.md）。実体のパスでも拒否する。
for df in "$HOME/.claude/CLAUDE.md" "$HOME/.claude2/CLAUDE.md" "$HOME/.claude/settings.json" "$HOME/.claude2/settings.json" "$PROPOSALS_DIR" "$LEDGER_DIR"; do
  while IFS= read -r dp; do
    if [ -d "$dp" ]; then disallowed+=("Edit(/$dp/**)"); else disallowed+=("Edit(/$dp)"); fi
  done < <(path_and_real "$df" | tail -n +2)
done

cmd=(claude -p "$PROMPT")
[ -n "${CLAUDE_REVIEW_LOOP_MODEL:-}" ] && cmd+=(--model "$CLAUDE_REVIEW_LOOP_MODEL")
[ -n "${CLAUDE_REVIEW_LOOP_EFFORT:-}" ] && cmd+=(--effort "$CLAUDE_REVIEW_LOOP_EFFORT")
cmd+=(--allowedTools "${allowed[@]}" --disallowedTools "${disallowed[@]}")

# コマンドを単一引用符で囲んだ形で表示する。printf %q は bash 3.2 でマルチバイト文字を壊すため使わない。
print_command() {
  local a sq="'\\''"
  printf "cd '%s' &&" "${stage//\'/$sq}"
  for a in "${cmd[@]}"; do
    printf " '%s'" "${a//\'/$sq}"
  done
  printf '\n'
}

if [ "$dry_run" -eq 1 ]; then
  for t in "${targets[@]}"; do printf 'TARGET: %s\n' "$t"; done
  print_command
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  log_error "claude が見つかりません（PATH: ${PATH}）"
  exit 1
fi

# 対象を複製する。元の絶対パスを複製先の下に保つ。
for t in "${targets[@]}"; do
  dest="$snap$t"
  if ! mkdir -p "${dest%/*}" || ! cp -Rp "$t" "$dest"; then
    log_error "複製に失敗しました: ${t} -> ${dest}。棚卸しを起動しません"
    exit 1
  fi
done
mkdir -p "$stage" || exit 1
log_info "複製しました: ${snap}"
# 古い実行の複製を RUN_KEEP 件まで減らす。
ls -1d "$STATE_DIR/runs/"*/ 2>/dev/null | LC_ALL=C sort -r | tail -n +$((RUN_KEEP + 1)) | while IFS= read -r old; do
  rm -rf -- "$old"
done

log_info "棚卸しを起動します（$(command -v claude)）"
print_command
(cd "$stage" && "${cmd[@]}")
rc=$?
[ "$rc" -ne 0 ] && log_error "棚卸しが異常終了しました（終了コード ${rc}）"

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/review-loop.XXXXXX")" || exit 1
trap 'rm -rf "$tmpd"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
added_out="$tmpd/added"
proposed_out="$tmpd/proposed"
skip_out="$tmpd/skip"
one_diff="$tmpd/one.diff"
: >"$added_out"
: >"$proposed_out"
: >"$skip_out"

only_additions() {
  ! diff -u "$1" "$2" | tail -n +3 | grep -q '^-'
}

changes=0
# deletions.tsv のうち、指定したメモリのディレクトリの直下にある削除の候補のファイル名を1行1件で出す。
deleted_names() {
  [ -f "$stage/deletions.tsv" ] || return 0
  awk -F'\t' -v d="$1/" 'index($1, d) == 1 && index(substr($1, length(d) + 1), "/") == 0 && $1 ~ /\.md$/ { print substr($1, length(d) + 1) }' "$stage/deletions.tsv"
}

# 承認待ちの案を1件作る。引数: <修正|追加|削除> <元の絶対パス> <元（新しいファイルなら /dev/null）> <直した版（削除なら /dev/null）> <理由>
# 修正と削除は Skill change-review の propose.sh で、行き先の表（<stage>/destinations<元の位置>/）と移し先への追加の差分を入れる。
# メモリの削除には、そのメモリを指す索引（MEMORY.md）の行の削除を含める。
make_proposal() {
  local kind="$1" target="$2" old="$3" new="$4" reason="$5" id c
  local check="対象のファイルが差分のとおりになっていること、関連するスキル・メモリの索引と食い違っていないことを確かめる。"
  local extra=()
  "$CR_SCRIPTS/diff-label.sh" "$old" "$new" "$target" >"$one_diff"
  [ $? -eq 1 ] || return 1
  if [ "$kind" = 追加 ]; then
    id="$("$CR_SCRIPTS/new-proposal.sh" --source "review-loop（${report}）" \
      --title "${target##*/} の${kind}（review-loop の棚卸し）" \
      --diff-file "$one_diff" --target "$target" --reason "$reason" --slug "review-loop" --check "$check")" || return 1
  else
    case "$target" in */memory/*.md) extra+=(--memory-index) ;; esac
    for c in "${config_dirs[@]}"; do extra+=(--allow-root "$c"); done
    id="$("$CR_SCRIPTS/propose.sh" --kind "$kind" --target "$target" --diff-file "$one_diff" \
      --dest-dir "$stage/destinations$(stage_rel "$target")" "${extra[@]}" \
      --source "review-loop（${report}）" --title "${target##*/} の${kind}（review-loop の棚卸し）" \
      --reason "$reason" --slug "review-loop" --check "${check%。}、移し先へ書き足されていることを確かめる。")" || return 1
  fi
  id="${id%%$'\n'*}"
  printf -- '- %s: `%s`（%s）\n' "$id" "$target" "$kind" >>"$proposed_out"
}

# 作業用のフォルダのパスから、対応する元のパスを求める。対象に当たらなければ空を出す。
dest_of() {
  local src="$1" i=0
  while [ "$i" -lt "${#targets[@]}" ]; do
    case "$src" in
      "${staged[$i]}"/*) printf '%s\n' "${targets[$i]}/${src#"${staged[$i]}"/}"; return 0 ;;
    esac
    i=$((i + 1))
  done
  # 新しいスキル: スキル置き場の下の新しいディレクトリ。
  for c in "${config_dirs[@]}"; do
    [ -d "$c/skills" ] || continue
    local sd
    sd="$(cd -P "$c/skills" && pwd -P)"
    case "$src" in
      "$stage$(stage_rel "$sd")"/*/*) printf '%s\n' "$sd/${src#"$stage$(stage_rel "$sd")"/}"; return 0 ;;
    esac
  done
  printf '\n'
}

if [ "$rc" -eq 0 ]; then
  while IFS= read -r src; do
    [ "$src" = "$stage/deletions.tsv" ] && continue
    [ "$src" = "$stage/summary.md" ] && continue
    case "$src" in "$stage/destinations/"*) continue ;; esac
    dest="$(dest_of "$src")"
    case "${src#$stage}" in
      *..*) printf -- '- `%s`: パスに .. を含む\n' "$src" >>"$skip_out"; continue ;;
    esac
    if [ -L "$src" ]; then
      printf -- '- `%s`: シンボリックリンクである\n' "$src" >>"$skip_out"; continue
    fi
    if [ -z "$dest" ]; then
      printf -- '- `%s`: 対象のスキル・メモリの中ではない\n' "$src" >>"$skip_out"; continue
    fi
    if [ -L "$dest" ]; then
      printf -- '- `%s`: 元の場所がシンボリックリンクである\n' "$dest" >>"$skip_out"; continue
    fi
    # 削除の候補を指す索引の行の削除は、削除の案に含める。ここでは消された索引の行を戻した版で比べる。
    if [ "${dest##*/}" = MEMORY.md ] && [ -f "$dest" ] && [ -n "$CR_SCRIPTS" ] && [ -n "$(deleted_names "${dest%/*}")" ]; then
      # shellcheck disable=SC2046
      python3 "$CR_SCRIPTS/memory-index.py" keep "$dest" "$src" $(deleted_names "${dest%/*}") >"$tmpd/MEMORY.md.kept" \
        && src="$tmpd/MEMORY.md.kept"
    fi
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
      continue
    fi
    if [ "$changes" -ge "$MAX_CHANGES" ]; then
      printf -- '- `%s`: 1回あたりの上限（%s件）を超えた\n' "$dest" "$MAX_CHANGES" >>"$skip_out"; continue
    fi
    if [ -f "$dest" ] && only_additions "$dest" "$src"; then
      if cp -p "$src" "$dest"; then
        changes=$((changes + 1))
        printf -- '- `%s`\n' "$dest" >>"$added_out"
      else
        printf -- '- `%s`: 書き戻しに失敗した\n' "$dest" >>"$skip_out"
      fi
      continue
    fi
    if [ -z "$CR_SCRIPTS" ]; then
      printf -- '- `%s`: Skill change-review が見つからず承認待ちを作れなかった\n' "$dest" >>"$skip_out"; continue
    fi
    if [ -f "$dest" ]; then
      kind=修正 old="$dest"
    else
      kind=追加 old=/dev/null
    fi
    if make_proposal "$kind" "$dest" "$old" "$src" "review-loop の自動の棚卸し（${ts}）が作った変更である。既存の行を変える・消す、または新しいファイルを作るため、自動では反映していない。"; then
      changes=$((changes + 1))
    else
      printf -- '- `%s`: 承認待ちの作成に失敗した\n' "$dest" >>"$skip_out"
    fi
  done < <(find "$stage" \( -type f -o -type l \) -print | LC_ALL=C sort)

  if [ -f "$stage/deletions.tsv" ]; then
    while IFS=$'\t' read -r dpath dreason || [ -n "$dpath" ]; do
      [ -n "$dpath" ] || continue
      dreason="${dreason:-理由の記載なし}"
      ok_target=0
      for t in "${targets[@]}"; do
        case "$dpath" in "$t"/*) ok_target=1 ;; esac
      done
      case "$dpath" in *..*) ok_target=0 ;; esac
      if [ "$ok_target" -ne 1 ] || [ -L "$dpath" ] || [ ! -f "$dpath" ]; then
        printf -- '- `%s`: 削除の候補だが、対象の中にあるファイルではない\n' "$dpath" >>"$skip_out"
      elif [ "$changes" -ge "$MAX_CHANGES" ]; then
        printf -- '- `%s`: 1回あたりの上限（%s件）を超えた\n' "$dpath" "$MAX_CHANGES" >>"$skip_out"
      elif [ -z "$CR_SCRIPTS" ]; then
        printf -- '- `%s`: 削除の候補だが、Skill change-review が見つからず承認待ちを作れなかった\n' "$dpath" >>"$skip_out"
      elif make_proposal 削除 "$dpath" "$dpath" /dev/null "review-loop の自動の棚卸し（${ts}）が挙げた削除の候補である。理由: ${dreason}"; then
        changes=$((changes + 1))
      else
        printf -- '- `%s`: 削除の承認待ちの作成に失敗した\n' "$dpath" >>"$skip_out"
      fi
    done <"$stage/deletions.tsv"
  fi
  # 書き戻した後の指紋を記録する。次回、利用者が何も変えていなければ起動しない。
  targets_hash >"$STATE_DIR/last-hash"
else
  log_error "棚卸しが異常終了したため、書き戻しと案の作成を行いません"
fi

n_added="$(grep -c . "$added_out" | tr -d ' ')"
n_prop="$(grep -c . "$proposed_out" | tr -d ' ')"
ids="$(sed -n 's/^- \([0-9][0-9-]*[^:]*\): .*/\1/p' "$proposed_out" | tr '\n' ' ' | sed 's/ $//; s/ /、/g')"
{
  printf '# 棚卸しの結果（review-loop）\n\n'
  if [ "$rc" -ne 0 ]; then
    printf '棚卸しが異常終了しました（終了コード %s）。書き戻しと案の作成は行っていません。ログ: %s\n' "$rc" "$STATE_DIR/logs/"
  fi
  printf -- '- 自動で反映した追加: %s件\n' "$n_added"
  printf -- '- 承認待ちにした変更: %s件（%s）\n' "$n_prop" "${ids:-なし}"
  printf '\n## 要点\n\n'
  if [ -s "$stage/summary.md" ]; then
    head -n 3 "$stage/summary.md"
  else
    printf '要点は書かれませんでした。\n'
  fi
  if [ -s "$added_out" ]; then printf '\n## 自動で反映した追加\n\n'; cat "$added_out"; fi
  if [ -s "$proposed_out" ]; then printf '\n## 承認待ちにした変更\n\n'; cat "$proposed_out"; fi
  if [ -s "$skip_out" ]; then printf '\n## 反映も案の作成もしなかったもの\n\n'; cat "$skip_out"; fi
  printf '\n直す前の複製: %s\n' "$snap"
} >"$report"
log_info "自動で反映した追加 ${n_added}件、承認待ち ${n_prop}件。結果: ${report}"
exit "$rc"
