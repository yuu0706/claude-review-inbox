#!/bin/bash
# memory-audit を非対話で起動する。対象は複製し、直したいことだけを共通の記録へ足す。
# 元のメモリ・索引・変更の台帳は書き換えない。bash 3.2 で動く書き方にする。
# 使い方: run.sh [--dry-run]
set -u

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
unset CLAUDE_CONFIG_DIR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
JOB_NAME="memory-audit"
REPORTS_ROOT="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORTS_ROOT="${REPORTS_ROOT%/}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
STATE_DIR="${STATE_BASE%/}/$JOB_NAME"
REPORT_DIR="$REPORTS_ROOT/$JOB_NAME"
TARGETS_CONF="${MEMORY_AUDIT_TARGETS:-$SCRIPT_DIR/targets.conf}"
LOG_KEEP=30
# 利用者の環境だけの決まりを書く上書きファイル。SKILL.md より優先して読ませる。
OVERRIDE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-skills/$JOB_NAME.local.md"

# jobs.conf の読み込み・設定ディレクトリの一覧・targets.conf の展開は、backfill-memory-repo.sh と共通の関数を使う。
. "$SCRIPT_DIR/memory-repo-lib.sh" || exit 1
# 起動するコマンド。空白で区切った語の {job} はジョブ名に置き換える（例: 別アカウントで起動するラッパー {job}）。
[ -n "${CLAUDE_LAUNCHER:-}" ] || CLAUDE_LAUNCHER="$(memory_jobs_conf CLAUDE_LAUNCHER)"
[ -n "$CLAUDE_LAUNCHER" ] || CLAUDE_LAUNCHER=claude
# 読み取りを拒否する追加の場所（コロン区切り）。クラウドストレージの同期フォルダ等を指定する。
[ -n "${CLAUDE_REVIEW_DENY_READ:-}" ] || CLAUDE_REVIEW_DENY_READ="$(memory_jobs_conf CLAUDE_REVIEW_DENY_READ)"
# Claude の設定ディレクトリ（CLAUDE_REVIEW_CONFIG_DIRS → jobs.conf → ~/.claude）のうち存在するもの。
config_dirs=()
while IFS= read -r d; do config_dirs+=("$d"); done < <(memory_config_dirs)
deny_read_extra=()
while IFS= read -r d; do deny_read_extra+=("$d"); done < <(memory_split_dirs "${CLAUDE_REVIEW_DENY_READ:-}")
skill_dirs=()
allow_roots=()
for c in ${config_dirs[@]+"${config_dirs[@]}"}; do skill_dirs+=("$c/skills"); allow_roots+=(--allow-root "$c"); done
# 否認リスト・訂正リストと、旧版から残る状態。
PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-$REPORTS_ROOT/proposals}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"
REJECTIONS="$PROPOSALS_DIR/rejections.md"
CORRECTIONS="$PROPOSALS_DIR/corrections.md"
LEDGER_DIR="${CLAUDE_REVIEW_STATE:-$HOME/.local/state/claude-review-inbox}"
LEDGER_DIR="${LEDGER_DIR%/}"
CHANGES_LOG="${CLAUDE_REVIEW_CHANGES_LOG:-$HOME/.local/state/claude-reports/changes/log.md}"

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

mkdir -p "$STATE_DIR/logs" "$REPORT_DIR/.snapshots" "$REPORT_DIR/.staging" || exit 1
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

if [ ! -f "$TARGETS_CONF" ]; then
  log_error "設定ファイルがありません: ${TARGETS_CONF}"
  exit 1
fi

targets=()
while IFS= read -r t; do targets+=("$t"); done < <(memory_list_targets "$TARGETS_CONF")
if [ "${#targets[@]}" -eq 0 ]; then
  log_error "対象のメモリのディレクトリが1件もありません（設定: ${TARGETS_CONF}）"
  exit 1
fi
log_info "対象のメモリ: ${#targets[@]}件（設定: ${TARGETS_CONF}）"

ts="$(date '+%Y-%m-%d-%H%M%S')"
snap="$REPORT_DIR/.snapshots/$ts"
stage="$REPORT_DIR/.staging/$ts"
n=2
while [ -e "$snap" ] || [ -e "$stage" ]; do
  snap="$REPORT_DIR/.snapshots/$ts-$n"; stage="$REPORT_DIR/.staging/$ts-$n"; n=$((n + 1))
done
report="$(next_report_path "$REPORT_DIR")"

# 作業用のフォルダの中での位置を求める。元の絶対パスの各要素のうち .claude で始まるもの（.claude・.claude-work 等）は、
# 先頭のドットを外して写す。claude -p はパスに .claude の要素を含む場所への Write を拒否するためである。
# 例: <HOME>/.claude/projects/X/memory -> <HOME>/claude/projects/X/memory
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

# 対象ごとの作業用での位置。targets と同じ順に並べる。書き戻しはこの対で照合し、文字列置換で推測しない。
staged=()
for t in "${targets[@]}"; do staged+=("$stage$(stage_rel "$t")"); done
mapping=""
i=0
while [ "$i" -lt "${#targets[@]}" ]; do
  mapping="${mapping}${mapping:+、}${targets[$i]} → ${staged[$i]}"
  i=$((i + 1))
done

# Skill change-review の scripts を探す。スキル置き場の change-review を経由し、リポジトリの絶対パスを埋め込まない。
find_change_review() {
  local c
  for c in "${CHANGE_REVIEW_SCRIPTS:-}" "$(dirname "$0")/../../change-review/scripts" \
    ${skill_dirs[@]+"${skill_dirs[@]/%//change-review/scripts}"}; do
    if [ -n "$c" ] && [ -x "$c/new-change.sh" ] && [ -x "$c/diff-label.sh" ] && [ -x "$c/propose.sh" ]; then
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

NEEDS="$stage/needs-approval.tsv"
PROMPT="Skill memory-audit を自動モードで実行する。対象のメモリは ${targets[*]}、直す前の複製は ${snap}、直した版の書き込み先は ${stage}（元の絶対パスの構造を保ち、.claude で始まる要素は先頭のドットを外して写す）、レポートの出力先は ${report}。対象ごとの元の位置と書き込み先での位置は次のとおり: ${mapping}。メモリは直接直さず、書き込み先へ直した版を書く。否認リストは ${REJECTIONS} にある。始める前に読み、否認リストと同じ対象・同じ趣旨の修正・削除は作らない。利用者の環境だけの決まりは ${OVERRIDE_FILE} にある（無ければ飛ばす）。削除の候補は ${stage}/deletions.tsv に「元の絶対パス<TAB>理由」の形で1行1件書く。削除の候補のメモリを指す索引（MEMORY.md）の行は消さない（シェルが、削除と同じ記録の差分に含める）。訂正リストは ${CORRECTIONS} にある。否認リストと同じく始める前に読み、訂正された変更を再び行わない。追加・修正・削除・統合はすべてシェルが記録に足す。元のファイルと記録のファイルは直接直さない。利用者の確認が要ると判断したもの（Skill change-review の要確認の条件、判断に迷うもの）は、${NEEDS} に「元の絶対パス<TAB>理由」の形で1行1件書く（シェルが要確認にする）。${DEST_RULE}"

# スキルの置き場所の直下にあるリンクの先の実体を求める共通の処理（Skill change-review の link-scopes.sh）を読み込む。
# claude -p の権限は実体のパスで判定されるため、リンクの先の実体を許可・拒否の規則に足す。
# 書き換えを拒否する規則（南京錠）もここから作るため、読み込めなければ起動しない。
for lsc in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" \
  ${skill_dirs[@]+"${skill_dirs[@]/%//change-review/scripts}"}; do
  [ -n "$lsc" ] && [ -f "$lsc/link-scopes.sh" ] && . "$lsc/link-scopes.sh" && break
done
# 南京錠（guard_deny_rules）が無いまま起動すると、安全のための規則やフックのスクリプトを書き換えられる。読み込めなければ起動しない。
if ! type guard_deny_rules >/dev/null 2>&1; then
  log_error "Skill change-review の link-scopes.sh を読み込めません。書き換えを拒否する規則を作れないため、精査を起動しません"
  exit 1
fi
link_reals=()
while IFS= read -r lr; do [ -n "$lr" ] && link_reals+=("$lr"); done < <(skill_link_reals ${skill_dirs[@]+"${skill_dirs[@]}"})

# 読んでよい範囲を設定ディレクトリ・結果の置き場所に限る。範囲を付けない Read・Glob・Grep と、
# 任意のパスを読める Bash（ls・grep 等）は許可しない。ホームの下の同期フォルダ等を検索すると、
# macOS がアクセス許可のダイアログを出すためである。which はパスの探索だけでファイルの中身を読まないため残す。
read_scopes=(${config_dirs[@]+"${config_dirs[@]}"} "$HOME/.agents" "$REPORTS_ROOT" "${STATE_BASE%/}")
allowed=(Skill "Bash(which:*)")
read_scopes+=("$PROPOSALS_DIR")
for d in "${read_scopes[@]}"; do allowed+=("Read(/$d/**)"); done
allowed+=("Read(/$OVERRIDE_FILE)")
for lr in ${link_reals[@]+"${link_reals[@]}"}; do allowed+=("Read(/$lr/**)"); done
allowed+=("Edit(/$stage/**)" "Edit(/$REPORT_DIR/*.md)")
disallowed=("Read(/$HOME/Library/CloudStorage/**)")
for d in ${deny_read_extra[@]+"${deny_read_extra[@]}"}; do disallowed+=("Read(/$d/**)"); done
disallowed+=("Edit(/$REPORT_DIR/.snapshots/**)")
for c in ${config_dirs[@]+"${config_dirs[@]}"}; do
  disallowed+=("Edit(/$c/CLAUDE.md)" "Edit(/$c/settings.json)" "Edit(/$c/skills/**)")
done
disallowed+=("Edit(/$HOME/Documents/**)" "Edit(/$PROPOSALS_DIR/**)" "Edit(/$LEDGER_DIR/**)" "Edit(/$CHANGES_LOG)")
for t in "${targets[@]}"; do
  disallowed+=("Edit(/$t/**)")
done
# スキルのリンクの先の実体も書き換えさせない。
for lr in ${link_reals[@]+"${link_reals[@]}"}; do disallowed+=("Edit(/$lr/**)"); done
# CLAUDE.md・settings.json は別の設定ディレクトリへのリンクのことがある。実体のパスでも拒否する。
deny_files=()
for c in ${config_dirs[@]+"${config_dirs[@]}"}; do deny_files+=("$c/CLAUDE.md" "$c/settings.json"); done
for df in ${deny_files[@]+"${deny_files[@]}"} "$PROPOSALS_DIR" "$LEDGER_DIR" "$CHANGES_LOG"; do
  while IFS= read -r dp; do
    if [ -d "$dp" ]; then disallowed+=("Edit(/$dp/**)"); else disallowed+=("Edit(/$dp)"); fi
  done < <(path_and_real "$df" | tail -n +2)
done
# 南京錠: 安全のための規則のスキル・フックと定期実行のスクリプト・設定ファイル・変更の台帳を、表記と実体の両方で拒否する。
while IFS= read -r gr; do disallowed+=("$gr"); done < <(guard_deny_rules ${config_dirs[@]+"${config_dirs[@]}"} -- \
  ${skill_dirs[@]+"${skill_dirs[@]}"})

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
  for t in "${targets[@]}"; do printf 'TARGET: %s\n' "$t"; done
  print_command
  exit 0
fi

# 対象を複製する。元の絶対パスを複製先の下に保つ（例: <snap><HOME>/.claude/projects/<p>/memory）。
for t in "${targets[@]}"; do
  dest="$snap$t"
  if ! mkdir -p "${dest%/*}" || ! cp -Rp "$t" "$dest"; then
    log_error "複製に失敗しました: ${t} -> ${dest}。精査を起動しません"
    exit 1
  fi
done
log_info "複製しました: ${snap}"
if ! mkdir -p "$stage"; then
  log_error "作業用のフォルダを作れません: ${stage}。精査を起動しません"
  exit 1
fi

log_info "精査を起動します"
print_command
(cd "$REPORT_DIR" && "${cmd[@]}")
rc=$?
if [ "$rc" -ne 0 ]; then
  log_error "精査が異常終了しました（終了コード ${rc}）"
fi

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/memory-audit-work.XXXXXX")" || exit 1
trap 'rm -rf "$tmpd"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
recorded="$tmpd/recorded"
skipped="$tmpd/skipped"
deletions="$tmpd/deletions"
: >"$recorded"; : >"$skipped"; : >"$deletions"
result_rc="$rc"

memory_name() {
  local proj="${1%/memory/*}"
  printf '%s/%s' "${proj##*/}" "${1##*/}"
}

kind_reason() {
  local target="$1" kind="$2" r n
  case "$target" in
    */CLAUDE.md|*/rejections.md|*/corrections.md) printf '共通方針または否認・訂正リストの変更'; return ;;
  esac
  if [ -f "$NEEDS" ]; then
    r="$(awk -F'\t' -v t="$target" '$1 == t { print ($2 == "" ? "理由の記載なし" : $2); exit }' "$NEEDS")"
    [ -z "$r" ] || { printf '精査が確認を要すると判断した（%s）' "$r"; return; }
  fi
  n="$(bash "$CR_SCRIPTS/corrections.sh" count "memory-audit/$kind/$(memory_name "$target")" 2>/dev/null)"
  if [ "${n:-0}" -ge 2 ]; then
    printf '同じ種類の変更（memory-audit/%s/%s）が訂正リストで %s 回訂正されている' "$kind" "$(memory_name "$target")" "$n"
  fi
}

# 区分は、propose.sh が行き先の表と安全の規則も調べた後の値を結果へ載せる。
record_summary() {
  local id="$1" target="$2" title="$3" k
  k="$(awk -v id="$id" '/^## / { found = ($NF == id) } found && /^- 区分: / { sub(/^- 区分: /, ""); print; exit }' "$CHANGES_LOG")"
  printf -- '- %s・%s・`%s`・%s\n' "$id" "$k" "$target" "$title" >>"$recorded"
}

record_change() {
  local kind="$1" target="$2" new="$3" reason="$4" id kr title before
  title="メモリ $(memory_name "$target") の${kind}（memory-audit の精査）"
  kr="$(kind_reason "$target" "$kind")"
  before="$snap$target"; [ -f "$before" ] || before=/dev/null
  "$CR_SCRIPTS/diff-label.sh" "$before" "$new" "$target" >"$tmpd/one.diff"
  [ $? -eq 1 ] || return 1
  if [ "$kind" = 追加 ]; then
    local extra=() k=直してよい
    [ -z "$kr" ] || { k=要確認; extra+=(--kind-reason "$kr"); }
    id="$("$CR_SCRIPTS/new-change.sh" --id-prefix memory-audit --kind "$k" ${extra[@]+"${extra[@]}"} \
      --source "memory-audit（${report}）" --title "$title" --target "$target" \
      --diff-file "$tmpd/one.diff" --reason "$reason")" || return 1
  else
    id="$("$CR_SCRIPTS/propose.sh" --id-prefix memory-audit --kind "$kind" \
      --category "memory-audit/$kind/$(memory_name "$target")" --kind-reason "$kr" \
      --target "$target" --diff-file "$tmpd/one.diff" \
      --dest-dir "$stage/destinations$(stage_rel "$target")" --memory-index \
      ${allow_roots[@]+"${allow_roots[@]}"} --source "memory-audit（${report}）" \
      --title "$title" --reason "$reason")" || return 1
  fi
  record_summary "${id%%$'\n'*}" "$target" "$title"
}

candidate_reason() {
  local src="$1" target="$2"
  case "${src#$stage}" in *..*) printf 'パスに .. を含む'; return 1 ;; esac
  [ ! -L "$src" ] || { printf 'シンボリックリンクである'; return 1; }
  case "$src" in *.md) ;; *) printf '拡張子が .md ではない'; return 1 ;; esac
  [ -n "$target" ] || { printf '対象のメモリのディレクトリの直下ではない'; return 1; }
  [ ! -L "$target" ] || { printf '元の場所がシンボリックリンクである'; return 1; }
  return 0
}

if [ "$rc" -eq 0 ] && [ -z "$CR_SCRIPTS" ]; then
  printf -- '- Skill change-review が見つからず、直したいことを記録できなかった。元のメモリは変更していない\n' >>"$skipped"
  result_rc=1
elif [ "$rc" -eq 0 ]; then
  # 索引を別の変更にしないよう、削除するメモリの名前を先に集める。
  if [ -f "$stage/deletions.tsv" ]; then
    while IFS=$'\t' read -r target reason || [ -n "$target" ]; do
      [ -n "$target" ] || continue
      valid=0
      for t in "${targets[@]}"; do [ "${target%/*}" = "$t" ] && valid=1; done
      case "$target" in *..*|*/MEMORY.md) valid=0 ;; *.md) ;; *) valid=0 ;; esac
      if [ "$valid" -eq 1 ] && [ -f "$target" ] && [ ! -L "$target" ]; then
        printf '%s\t%s\n' "$target" "${reason:-理由の記載なし}" >>"$deletions"
      else
        printf -- '- `%s`: 削除の候補だが、対象のメモリのディレクトリの直下にある .md ではない\n' "$target" >>"$skipped"
      fi
    done <"$stage/deletions.tsv"
  fi
  while IFS= read -r src; do
    case "$src" in "$stage/deletions.tsv"|"$NEEDS"|"$stage/destinations/"*) continue ;; esac
    target=""; i=0
    while [ "$i" -lt "${#targets[@]}" ]; do
      if [ "${src%/*}" = "${staged[$i]}" ]; then target="${targets[$i]}/${src##*/}"; break; fi
      i=$((i + 1))
    done
    if ! why="$(candidate_reason "$src" "$target")"; then
      printf -- '- `%s`: %s\n' "${target:-$src}" "$why" >>"$skipped"; continue
    fi
    awk -F'\t' -v t="$target" '$1 == t { found = 1 } END { exit !found }' "$deletions" && continue
    if [ "${target##*/}" = MEMORY.md ] && [ -s "$deletions" ]; then
      names=()
      while IFS=$'\t' read -r dpath dreason; do
        [ "${dpath%/*}" = "${target%/*}" ] && names+=("${dpath##*/}")
      done <"$deletions"
      if [ "${#names[@]}" -gt 0 ]; then
        python3 -B "$CR_SCRIPTS/memory-index.py" keep "$target" "$src" "${names[@]}" >"$tmpd/MEMORY.md.kept" || { result_rc=1; continue; }
        src="$tmpd/MEMORY.md.kept"
      fi
    fi
    before="$snap$target"
    [ -f "$before" ] && cmp -s "$before" "$src" && continue
    kind=修正
    if [ ! -f "$before" ] || ! diff -u "$before" "$src" | tail -n +3 | grep -q '^-'; then kind=追加; fi
    if ! record_change "$kind" "$target" "$src" "memory-audit の精査（${ts}）。根拠はレポート ${report} を参照する。"; then
      printf -- '- `%s`: 記録への追記に失敗した\n' "$target" >>"$skipped"; result_rc=1
    fi
  done < <(find "$stage" \( -type f -o -type l \) -print | LC_ALL=C sort)
  while IFS=$'\t' read -r target reason; do
    [ -n "$target" ] || continue
    if ! record_change 削除 "$target" /dev/null "memory-audit の精査（${ts}）が挙げた削除の候補。理由: ${reason}。根拠はレポート ${report} を参照する。"; then
      printf -- '- `%s`: 削除の記録への追記に失敗した\n' "$target" >>"$skipped"; result_rc=1
    fi
  done <"$deletions"
fi

{
  [ -s "$report" ] || printf '# メモリ精査レポート\n\nレポートが作られませんでした（精査の終了コード %s）。\n' "$rc"
  printf '\n## 記録に足した直したいこと（ID・区分・対象・要約）\n\n'
  if [ -s "$recorded" ]; then cat "$recorded"; else printf 'なし\n'; fi
  printf '\n## 記録しなかった候補\n\n'
  if [ "$rc" -ne 0 ]; then
    printf '精査が異常終了したため（終了コード %s）、記録に足していない。\n' "$rc"
  elif [ -s "$skipped" ]; then cat "$skipped"; else printf 'なし\n'; fi
  printf '\n元のメモリと索引は変更していない。\n'
} >>"$report"
log_info "直したいことを記録しました: $(grep -c '^- ' "$recorded" | tr -d ' ')件（結果 ${report}）"
exit "$result_rc"
