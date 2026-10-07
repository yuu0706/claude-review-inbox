#!/bin/bash
# memory-audit を非対話で起動する。launchd から週1回呼ばれる。
# 対象のメモリを複製してから claude（CLAUDE_LAUNCHER）を起動する。claude には直した版を作業用のフォルダ（.staging）へ書かせ、
# 正常終了した場合だけ、条件を満たすファイルを元のメモリへ書き戻す。最後に複製との差分をレポートの末尾へ足す。
# 書き戻すのは、既存の行を変えない・消さない変更（diff の - 行が無いもの）だけである。それ以外の修正と、
# claude が deletions.tsv に挙げた削除の候補は、書き戻さずに Skill change-review の承認待ちの案にする（案はシェルで作る）。
# 修正・削除の案には、claude が候補ごとに作った「消える記述の行き先」の表と、移し先への追加の差分を入れる（Skill change-review「2.2」）。
# メモリの削除の案には、そのメモリを指す索引（MEMORY.md）の行の削除も入れ、索引だけの案を別に作らない。
# claude -p では ~/.claude 配下が保護対象のファイルとして扱われ、Edit を許可しても書き込めないため、この方式を採る。
# 使い方: run.sh [--dry-run]
#   --dry-run  複製も起動もせず、対象と組み立てたコマンドを標準出力へ表示する。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。
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
# 承認待ちの置き場所・否認リスト・判断の台帳（claude-review-inbox）。
PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-$REPORTS_ROOT/proposals}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"
REJECTIONS="$PROPOSALS_DIR/rejections.md"
LEDGER_DIR="${CLAUDE_REVIEW_STATE:-$HOME/.local/state/claude-review-inbox}"
LEDGER_DIR="${LEDGER_DIR%/}"

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
report="$(next_report_path "$REPORT_DIR")"

# 作業用のフォルダの中での位置を求める。元の絶対パスの各要素のうち .claude で始まるもの（.claude・.claude2 等）は、
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

PROMPT="Skill memory-audit を自動モードで実行する。対象のメモリは ${targets[*]}、直す前の複製は ${snap}、直した版の書き込み先は ${stage}（元の絶対パスの構造を保ち、.claude で始まる要素は先頭のドットを外して写す）、レポートの出力先は ${report}。対象ごとの元の位置と書き込み先での位置は次のとおり: ${mapping}。メモリは直接直さず、書き込み先へ直した版を書く。否認リストは ${REJECTIONS} にある。始める前に読み、否認リストと同じ対象・同じ趣旨の修正・削除は作らない。利用者の環境だけの決まりは ${OVERRIDE_FILE} にある（無ければ飛ばす）。削除の候補は ${stage}/deletions.tsv に「元の絶対パス<TAB>理由」の形で1行1件書く。削除の候補のメモリを指す索引（MEMORY.md）の行は消さない（シェルが削除の案に含める）。${DEST_RULE}"

# スキルの置き場所の直下にあるリンクの先の実体を求める共通の処理（Skill change-review の link-scopes.sh）を読み込む。
# claude -p の権限は実体のパスで判定されるため、リンクの先の実体を許可・拒否の規則に足す。
# 読み込めない場合も動くよう、最小の処理で代える。
for lsc in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" \
  ${skill_dirs[@]+"${skill_dirs[@]/%//change-review/scripts}"}; do
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
    local loc e
    for loc in "$@"; do
      for e in "$loc" "$loc"/*; do
        [ -L "$e" ] && [ -d "$e" ] && (cd -P "$e" 2>/dev/null && pwd -P)
      done
    done | awk '!seen[$0]++'
    return 0
  }
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
disallowed+=("Edit(/$HOME/Documents/**)" "Edit(/$PROPOSALS_DIR/**)" "Edit(/$LEDGER_DIR/**)")
for t in "${targets[@]}"; do
  disallowed+=("Edit(/$t/**)")
done
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

# 起動に使うコマンド（CLAUDE_LAUNCHER）。語の {job} はジョブ名に置き換える。
launcher=()
read -r -a launcher_words <<<"$CLAUDE_LAUNCHER"
for w in "${launcher_words[@]}"; do
  [ "$w" = "{job}" ] && w="$JOB_NAME"
  launcher+=("$w")
done
log_info "起動に使うコマンド: ${launcher[*]}"
cmd=("${launcher[@]}" -p "$PROMPT" --model opus --effort low
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

diff_out="$(mktemp "${TMPDIR:-/tmp}/memory-audit-diff.XXXXXX")" || exit 1
skip_out="$(mktemp "${TMPDIR:-/tmp}/memory-audit-skip.XXXXXX")" || exit 1
added_out="$(mktemp "${TMPDIR:-/tmp}/memory-audit-added.XXXXXX")" || exit 1
proposed_out="$(mktemp "${TMPDIR:-/tmp}/memory-audit-proposed.XXXXXX")" || exit 1
one_diff="$(mktemp "${TMPDIR:-/tmp}/memory-audit-one.XXXXXX")" || exit 1
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/memory-audit-work.XXXXXX")" || exit 1
trap 'rm -f "$diff_out" "$skip_out" "$added_out" "$proposed_out" "$one_diff"; rm -rf "$tmpd"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# 既存の行を変えない・消さない変更（diff の - 行が無い）なら 0 を返す。
only_additions() {
  ! diff -u "$1" "$2" | tail -n +3 | grep -q '^-'
}

# deletions.tsv のうち、指定したメモリのディレクトリの直下にある削除の候補のファイル名を1行1件で出す。
deleted_names() {
  [ -f "$stage/deletions.tsv" ] || return 0
  awk -F'\t' -v d="$1/" 'index($1, d) == 1 && index(substr($1, length(d) + 1), "/") == 0 && $1 ~ /\.md$/ { print substr($1, length(d) + 1) }' "$stage/deletions.tsv"
}

# 承認待ちの案を1件作り、番号を proposed_out へ記録する。引数: <修正|削除> <元の絶対パス> <直した版（削除なら /dev/null）> <理由>
# 行き先の表は claude が書いた <stage>/destinations<元の位置>/ から読み、移し先への追加の差分も同じ案に入れる（自動では反映しない）。
# 削除の案には、そのメモリを指す索引（MEMORY.md）の行の削除を含める（Skill change-review の propose.sh）。
make_proposal() {
  local kind="$1" target="$2" new="$3" reason="$4" proj id slug=memory-audit-edit
  [ "$kind" = 削除 ] && slug=memory-audit-delete
  proj="${target%/memory/*}"
  proj="${proj##*/}"
  "$CR_SCRIPTS/diff-label.sh" "$target" "$new" "$target" >"$one_diff"
  [ $? -eq 1 ] || return 1
  id="$("$CR_SCRIPTS/propose.sh" --kind "$kind" --target "$target" --diff-file "$one_diff" \
    --dest-dir "$stage/destinations$(stage_rel "$target")" --memory-index \
    ${allow_roots[@]+"${allow_roots[@]}"} \
    --source "memory-audit（${report}）" \
    --title "メモリ ${proj}/${target##*/} の${kind}（memory-audit の精査）" \
    --reason "$reason" --slug "$slug" \
    --check "対象のファイルが差分のとおりになっていること、MEMORY.md の索引と食い違っていないこと、移し先へ書き足されていることを確かめる。")" || return 1
  id="${id%%$'\n'*}"
  printf -- '- %s: `%s`（%s）\n' "$id" "$target" "$kind" >>"$proposed_out"
}

# 書き戻してよい場所かを判定する。よければ0を返し、だめなら理由を標準出力へ書いて1を返す。
# 引数: <作業用のフォルダのファイル> <元の場所（対象に当たらなければ空）>
writeback_reason() {
  local src="$1" dest="$2"
  case "${src#$stage}" in
    *..*) printf 'パスに .. を含む'; return 1 ;;
  esac
  if [ -L "$src" ]; then
    printf 'シンボリックリンクである'; return 1
  fi
  case "$src" in
    *.md) ;;
    *) printf '拡張子が .md ではない'; return 1 ;;
  esac
  if [ -z "$dest" ]; then
    printf '対象のメモリのディレクトリの直下ではない'; return 1
  fi
  if [ -L "$dest" ]; then
    printf '元の場所がシンボリックリンクである'; return 1
  fi
  if [ ! -f "$dest" ]; then
    printf '元の場所に同名のファイルが無い（新しいファイルは作らない）'; return 1
  fi
  return 0
}

# 精査が正常終了した場合だけ、作業用のフォルダから元の場所へ書き戻す。削除は一切しない。
written=0
if [ "$rc" -eq 0 ]; then
  while IFS= read -r src; do
    # 親のディレクトリが対象の作業用での位置と一致する場合だけ、その対象の直下を元の場所とする。
    dest=""
    i=0
    while [ "$i" -lt "${#targets[@]}" ]; do
      if [ "${src%/*}" = "${staged[$i]}" ]; then
        dest="${targets[$i]}/${src##*/}"
        break
      fi
      i=$((i + 1))
    done
    [ "$src" = "$stage/deletions.tsv" ] && continue
    case "$src" in "$stage/destinations/"*) continue ;; esac
    if reason="$(writeback_reason "$src" "$dest")"; then
      # 削除の候補を指す索引の行の削除は、削除の案に含める。ここでは消された索引の行を戻した版で比べる。
      if [ "${dest##*/}" = MEMORY.md ] && [ -n "$CR_SCRIPTS" ] && [ -n "$(deleted_names "${dest%/*}")" ]; then
        # shellcheck disable=SC2046
        python3 "$CR_SCRIPTS/memory-index.py" keep "$dest" "$src" $(deleted_names "${dest%/*}") >"$tmpd/MEMORY.md.kept" \
          && src="$tmpd/MEMORY.md.kept"
      fi
      if cmp -s "$src" "$dest"; then
        :
      elif only_additions "$dest" "$src"; then
        if cp -p "$src" "$dest"; then
          written=$((written + 1))
          printf -- '- `%s`\n' "$dest" >>"$added_out"
        else
          printf -- '- `%s`: 書き戻しに失敗した\n' "$dest" >>"$skip_out"
        fi
      elif [ -z "$CR_SCRIPTS" ]; then
        printf -- '- `%s`: 既存の行を変える修正だが、Skill change-review が見つからず承認待ちを作れなかった\n' "$dest" >>"$skip_out"
      elif ! make_proposal 修正 "$dest" "$src" "memory-audit の自動の精査（${ts}）が作った修正である。既存の行を変える・消すため、自動では反映していない。根拠はレポート ${report} を参照する。"; then
        printf -- '- `%s`: 承認待ちの作成に失敗した\n' "$dest" >>"$skip_out"
      fi
    else
      printf -- '- `%s`: %s\n' "${dest:-$src}" "$reason" >>"$skip_out"
    fi
  done < <(find "$stage" \( -type f -o -type l \) -print | LC_ALL=C sort)
  log_info "書き戻しました: ${written}件"

  # 削除の候補（claude が deletions.tsv に書いたもの）を、削除の案にする。メモリのファイルは消さない。
  if [ -f "$stage/deletions.tsv" ]; then
    while IFS=$'\t' read -r dpath dreason || [ -n "$dpath" ]; do
      [ -n "$dpath" ] || continue
      dreason="${dreason:-理由の記載なし}"
      ok_target=0
      for t in "${targets[@]}"; do
        [ "${dpath%/*}" = "$t" ] && ok_target=1
      done
      case "$dpath" in
        *..*) ok_target=0 ;;
        *.md) ;;
        *) ok_target=0 ;;
      esac
      if [ "$ok_target" -ne 1 ] || [ -L "$dpath" ] || [ ! -f "$dpath" ]; then
        printf -- '- `%s`: 削除の候補だが、対象のメモリのディレクトリの直下にある .md ではない\n' "$dpath" >>"$skip_out"
      elif [ -z "$CR_SCRIPTS" ]; then
        printf -- '- `%s`: 削除の候補だが、Skill change-review が見つからず承認待ちを作れなかった\n' "$dpath" >>"$skip_out"
      elif ! make_proposal 削除 "$dpath" /dev/null "memory-audit の自動の精査（${ts}）が挙げた削除の候補である。理由: ${dreason}"; then
        printf -- '- `%s`: 削除の承認待ちの作成に失敗した\n' "$dpath" >>"$skip_out"
      fi
    done <"$stage/deletions.tsv"
  fi
  log_info "承認待ちにしました: $(grep -c . "$proposed_out" | tr -d ' ')件"
else
  log_error "精査が異常終了したため、書き戻しを行いません"
fi

# 複製と現在のメモリの差分をレポートの末尾へ足す。
for t in "${targets[@]}"; do
  diff -ru "$snap$t" "$t" >>"$diff_out" 2>&1
done
{
  [ -s "$report" ] || printf '# メモリ精査レポート\n\nレポートが作られませんでした（精査の終了コード %s）。\n' "$rc"
  n_added="$(grep -c . "$added_out" | tr -d ' ')"
  n_prop="$(grep -c . "$proposed_out" | tr -d ' ')"
  ids="$(sed -n 's/^- \([0-9-]*\): .*/\1/p' "$proposed_out" | tr '\n' ' ' | sed 's/ $//; s/ /、/g')"
  printf '\n## 自動で反映した追加と承認待ち\n\n'
  printf '自動で反映した追加 %s件 / 承認待ちにした %s件（%s）（スクリプトが追記した）。\n' "$n_added" "$n_prop" "${ids:-なし}"
  printf '既存の行を変えない・消さない変更だけを自動で反映し、それ以外の修正と削除の候補は Skill change-review の承認待ち（%s）にした。\n' "$PROPOSALS_DIR"
  if [ -s "$added_out" ]; then printf '\n### 自動で反映した追加\n\n'; cat "$added_out"; fi
  if [ -s "$proposed_out" ]; then printf '\n### 承認待ちにした変更\n\n'; cat "$proposed_out"; fi
  printf '\n## 書き戻さなかったファイル\n\n'
  printf '作業用のフォルダ %s のうち、元のメモリへ書き戻さなかったファイルである（スクリプトが追記した）。\n\n' "$stage"
  if [ "$rc" -ne 0 ]; then
    printf '精査が異常終了したため（終了コード %s）、すべて書き戻していない。\n' "$rc"
  elif [ -s "$skip_out" ]; then
    cat "$skip_out"
  else
    printf 'なし\n'
  fi
  printf '\n## 変更の差分\n\n'
  printf '複製 %s と現在のメモリを diff -ru で比べた結果である（スクリプトが追記した）。\n\n' "$snap"
  if [ -s "$diff_out" ]; then
    printf '```diff\n'
    cat "$diff_out"
    printf '```\n'
  else
    printf '変更なし\n'
  fi
} >>"$report"
log_info "差分を追記しました: ${report}"

exit "$rc"
