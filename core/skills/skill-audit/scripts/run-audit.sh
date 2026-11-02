#!/bin/bash
# skill-audit を非対話で起動する。launchd から週1回呼ばれる。
# 使い方: run-audit.sh [--force] [--dry-run]
#   --force    変更が無くても起動する
#   --dry-run  起動せず、組み立てたコマンドを標準出力へ表示する。last-hash は更新しない。
# 対象を before と staging に複製し、claude は staging だけを編集する。
# 追加・修正・削除・統合を共通の記録へ足し、元のスキルと履歴は変更しない。
set -u

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
unset CLAUDE_CONFIG_DIR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib.sh"
# 利用者の環境だけの決まりを書く上書きファイル。SKILL.md より優先して読ませる。
OVERRIDE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-skills/$SELF_NAME.local.md"

# 否認リスト・訂正リストと、旧版から残る状態。
PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"
REJECTIONS="$PROPOSALS_DIR/rejections.md"
CORRECTIONS="$PROPOSALS_DIR/corrections.md"
# 結果（未読の知らせに出るもの）の置き場所。公開版の点検（check-public.sh）と同じ場所に書く。
RESULT_DIR="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
RESULT_DIR="${RESULT_DIR%/}/$SELF_NAME"
# 修正・削除を常に要確認にするスキル（安全のための規則）。空白区切り。
[ -n "${SKILL_AUDIT_PROTECTED:-}" ] || SKILL_AUDIT_PROTECTED="$(jobs_conf SKILL_AUDIT_PROTECTED)"
read -r -a PROTECTED_NAMES <<<"${SKILL_AUDIT_PROTECTED:-security-rules commit-guard}"
LEDGER_DIR="${CLAUDE_REVIEW_STATE:-$HOME/.local/state/claude-review-inbox}"
LEDGER_DIR="${LEDGER_DIR%/}"
CHANGES_LOG="${CLAUDE_REVIEW_CHANGES_LOG:-$HOME/.local/state/claude-reports/changes/log.md}"
LOG_KEEP=30
RUN_KEEP=10

force=0
dry_run=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    *) log_error "不明な引数です: $arg"; exit 2 ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  log_error "ROOT が存在しません: $ROOT"
  exit 1
fi

mkdir -p "$STATE_DIR/logs" || exit 1

LOCK_DIR="$STATE_DIR/lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_error "別の実行が進行中です（$LOCK_DIR が存在します）"
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

# 公開版の点検は、スキルの変更の有無に関わらず毎回行う。当たりや検査器が無いことは結果に書かれるため、精査は止めない。
# 点検が結果を書いたら、そのファイルに精査の結果も足す（同じ実行の結果を1つのファイルにまとめる）。
PUBLIC_REPORT=""
if [ "$dry_run" -eq 0 ]; then
  pc_out="$(bash "$SCRIPT_DIR/check-public.sh")" || log_info "公開版の点検で知らせる事項がありました"
  [ -n "$pc_out" ] && printf '%s\n' "$pc_out"
  PUBLIC_REPORT="$(printf '%s\n' "$pc_out" | sed -n 's/^公開版の点検: 結果を書きました: //p' | tail -n 1)"
fi

# 対象配下の全ファイルのパスと内容から sha256 を1つ計算する。
# 対象のスキルそのものがリンク（自作のスキルのリンク）なら実体の中を数える。
# スキルの中のシンボリックリンクは辿らず、リンク先の文字列を使う。
compute_hash() {
  local t f
  list_targets | while IFS= read -r t; do
    find -H "$ROOT/$t" \( -type f -o -type l \) -print
  done | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      printf 'L %s %s\n' "${f#$ROOT/}" "$(readlink "$f")"
    else
      printf 'F %s %s\n' "${f#$ROOT/}" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
    fi
  done | shasum -a 256 | cut -d' ' -f1
}

current_hash="$(compute_hash)"
last_hash=""
[ -f "$STATE_DIR/last-hash" ] && last_hash="$(cat "$STATE_DIR/last-hash")"

if [ "$force" -eq 0 ] && [ "$current_hash" = "$last_hash" ]; then
  log_info "変更なし。精査を省略します（hash=${current_hash}）"
  exit 0
fi

# スキルの置き場所の直下にあるリンクの先の実体を求める共通の処理（Skill change-review の link-scopes.sh）を読み込む。
# claude -p の権限は実体のパスで判定されるため、リンクの先の実体を許可・拒否の規則に足す。
# 書き換えを拒否する規則（南京錠）もここから作るため、読み込めなければ起動しない。
for lsc in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" \
  "$ROOT/change-review/scripts" ${SKILL_DIRS[@]+"${SKILL_DIRS[@]/%//change-review/scripts}"}; do
  [ -n "$lsc" ] && [ -f "$lsc/link-scopes.sh" ] && . "$lsc/link-scopes.sh" && break
done
# 南京錠（guard_deny_rules）が無いまま起動すると、安全のための規則やフックのスクリプトを書き換えられる。読み込めなければ起動しない。
if ! type guard_deny_rules >/dev/null 2>&1; then
  log_error "Skill change-review の link-scopes.sh を読み込めません。書き換えを拒否する規則を作れないため、精査を起動しません"
  exit 1
fi
link_reals=()
while IFS= read -r lr; do [ -n "$lr" ] && link_reals+=("$lr"); done < <(skill_link_reals "$ROOT" ${SKILL_DIRS[@]+"${SKILL_DIRS[@]}"})

# Skill change-review の scripts を探す。スキル置き場の change-review を経由し、リポジトリの絶対パスを埋め込まない。
find_change_review() {
  local c
  for c in "${CHANGE_REVIEW_SCRIPTS:-}" "$(dirname "$0")/../../change-review/scripts" \
    "$ROOT/change-review/scripts" ${SKILL_DIRS[@]+"${SKILL_DIRS[@]/%//change-review/scripts}"}; do
    if [ -n "$c" ] && [ -x "$c/new-change.sh" ] && [ -x "$c/diff-label.sh" ] && [ -x "$c/propose.sh" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# 作業用のフォルダの中での位置を求める。元の絶対パスの各要素のうち .claude で始まるもの（.claude・.claude-work 等）は、
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

ts="$(date '+%Y-%m-%d-%H%M%S')"
RUN_DIR="$STATE_DIR/runs/$ts"
# 同じ秒の2回目以降は -2、-3 と連番にし、前の実行の複製と行き先の表を使い回さない。
n=2
while [ -e "$RUN_DIR" ]; do RUN_DIR="$STATE_DIR/runs/$ts-$n"; n=$((n + 1)); done
STAGE="$RUN_DIR/staging"
BEFORE="$RUN_DIR/before"
DEST_BASE="$RUN_DIR/destinations"
NEEDS="$RUN_DIR/needs-approval.tsv"
CR_SCRIPTS="$(find_change_review)" || CR_SCRIPTS=""
PROMPT="Skill skill-audit を自動モードで実行する。対象のスキルは ${ROOT}、直す前の複製は ${BEFORE}、直した版の書き込み先は ${STAGE}。対象と同じ相対パスで作業用の複製だけを直す。元のスキルと変更の記録と history.md は直接直さない。追加・修正・削除・統合はすべてシェルが直したいことの記録に足す。削除の候補は ${RUN_DIR}/deletions.tsv に「対象の元の絶対パス<TAB>理由」の形で書く（スキル全体を消すならスキルのディレクトリ）。作業用の複製の削除も候補として扱う。スキルを削除する場合、その参照を消す修正も作業用の複製に作る。snapshot.sh と trash-skill.sh は呼ばない。利用者の確認が要るものと判断に迷うものは ${NEEDS} に「対象の元の絶対パス<TAB>理由」の形で書く。否認リストは ${REJECTIONS}、訂正リストは ${CORRECTIONS} にある。始める前に読み、否認や訂正と同じ対象・同じ趣旨の変更を作らない。利用者の環境だけの決まりは ${OVERRIDE_FILE} にある（無ければ飛ばす）。移し先への追加は、移し先を直接直さず行き先のフォルダに置く。"
if [ -n "$CR_SCRIPTS" ]; then
  PROMPT="${PROMPT}$("$CR_SCRIPTS/destinations.sh" --print-rule "$DEST_BASE")"
fi

# 許可する規則。読んでよい範囲を設定ディレクトリ（スキル・メモリ）・結果の置き場所と ROOT に限る。
# 範囲を付けない Read・Glob・Grep と、任意のパスを読める Bash（ls・grep・diff 等）は許可しない。
# ホームの下の同期フォルダ等を検索すると、macOS がアクセス許可のダイアログを出すためである。
read_scopes=(${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"} "$HOME/.agents" "${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
  "$HOME/.local/state/claude-reports" "$ROOT" "$PROPOSALS_DIR" "$RUN_DIR" "$HISTORY_DIR")
allowed=(Skill "Bash(date:*)" "Edit(/$STAGE/**)" "Edit(/$DEST_BASE/**)" "Edit(/$NEEDS)"
  "Edit(/$RUN_DIR/deletions.tsv)" "Read(/$HISTORY_FILE)" "Read(/$OVERRIDE_FILE)")
for d in "${read_scopes[@]}"; do allowed+=("Read(/$d/**)"); done
for lr in ${link_reals[@]+"${link_reals[@]}"}; do allowed+=("Read(/$lr/**)"); done

# 拒否する規則。設定ディレクトリの skills が ROOT への別名（リンク）なら、そちらの表記も拒否する。
roots=("$ROOT")
root_real="$(cd -P "$ROOT" && pwd -P)"
for alias_root in ${SKILL_DIRS[@]+"${SKILL_DIRS[@]}"}; do
  [ "$alias_root" = "$ROOT" ] && continue
  if [ -L "$alias_root" ] && [ "$(resolve_link "$alias_root")" = "$root_real" ]; then
    roots+=("$alias_root")
  fi
done

deny_names=(${EXCLUDE_NAMES[@]+"${EXCLUDE_NAMES[@]}"} .trash .skill-audit-trash)
while IFS= read -r n; do deny_names+=("$n"); done < <(list_dot_entries)

disallowed=("Read(/$HOME/Library/CloudStorage/**)")
for d in ${DENY_READ_EXTRA[@]+"${DENY_READ_EXTRA[@]}"}; do disallowed+=("Read(/$d/**)"); done
seen=" "
add_deny() {
  case "$seen" in *" $1 "*) return ;; esac
  seen="$seen$1 "
  disallowed+=("$1")
}
for r in "${roots[@]}"; do
  for n in "${deny_names[@]}"; do
    add_deny "Edit(/$r/$n/**)"
  done
done
while IFS= read -r n; do
  is_target "$n" && continue
  for r in "${roots[@]}"; do
    add_deny "Edit(/$r/$n/**)"
  done
  real="$(resolve_link "$ROOT/$n")"
  [ -n "$real" ] && [ -e "$real" ] && add_deny "Edit(/$real/**)"
done < <(list_symlinks)
for r in "${roots[@]}"; do add_deny "Edit(/$r/**)"; done
for lr in ${link_reals[@]+"${link_reals[@]}"}; do add_deny "Edit(/$lr/**)"; done
add_deny "Edit(/$BEFORE/**)"
add_deny "Edit(/$HISTORY_FILE)"
add_deny "Edit(/$HISTORY_DIR/**)"
add_deny "Edit(/$CHANGES_LOG)"
add_deny "Edit(/$HOME/.agents/**)"
add_deny "Edit(/$HOME/Documents/**)"
deny_files=()
for c in ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do deny_files+=("$c/CLAUDE.md" "$c/settings.json"); done
for df in ${deny_files[@]+"${deny_files[@]}"}; do add_deny "Edit(/$df)"; done
add_deny "Edit(/$PROPOSALS_DIR/**)"
add_deny "Edit(/$LEDGER_DIR/**)"
# CLAUDE.md・settings.json・否認リストの置き場所・台帳・共通の記録がリンクなら（別の設定ディレクトリの CLAUDE.md へのリンク等）、実体のパスでも拒否する。
for df in ${deny_files[@]+"${deny_files[@]}"} "$PROPOSALS_DIR" "$LEDGER_DIR" "$CHANGES_LOG"; do
  while IFS= read -r dp; do
    if [ -d "$dp" ]; then add_deny "Edit(/$dp/**)"; else add_deny "Edit(/$dp)"; fi
  done < <(path_and_real "$df" | tail -n +2)
done
# 南京錠: 安全のための規則のスキル・フックと定期実行のスクリプト・設定ファイル・変更の台帳を、表記と実体の両方で拒否する。
# 自作のスキルの実体（Edit(/<実体>/**)）を許可していても、拒否の規則が優先する。
while IFS= read -r gr; do add_deny "$gr"; done < <(guard_deny_rules ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"} -- \
  "${roots[@]}" ${SKILL_DIRS[@]+"${SKILL_DIRS[@]}"})

# 起動に使うコマンド（CLAUDE_LAUNCHER）。語の {job} はジョブ名に置き換える。
launcher=()
read -r -a launcher_words <<<"$CLAUDE_LAUNCHER"
for w in "${launcher_words[@]}"; do
  [ "$w" = "{job}" ] && w="$SELF_NAME"
  launcher+=("$w")
done
log_info "起動に使うコマンド: ${launcher[*]}"
# --permission-mode default: settings.json の defaultMode（acceptEdits 等）で作業場所（ROOT）の中の編集が
# 許可なしに通らないようにし、許可を --allowedTools だけで決める。
cmd=("${launcher[@]}" -p "$PROMPT" --model opus --effort low --permission-mode default
  --allowedTools "${allowed[@]}" --disallowedTools "${disallowed[@]}")

# コマンドを単一引用符で囲んだ形で表示する。printf %q は bash 3.2 でマルチバイト文字を壊すため使わない。
print_command() {
  local a sq="'\\''"
  printf "cd '%s' &&" "${STAGE//\'/$sq}"
  for a in "${cmd[@]}"; do
    printf " '%s'" "${a//\'/$sq}"
  done
  printf '\n'
}

if [ "$dry_run" -eq 1 ]; then
  print_command
  exit 0
fi

# ---- 作業用の複製の比較と記録 ----
RECORDED="$RUN_DIR/recorded.txt"
NOTES="$RUN_DIR/notes.txt"

# needs-approval は元の絶対パスを使う。スキル全体の指定は配下の変更にも適用する。
kind_reason() {
  local target="$1" kind="$2" skill="$3" r n p
  case "$target" in
    */CLAUDE.md|*/rejections.md|*/corrections.md) printf '共通方針または否認・訂正リストの変更'; return ;;
  esac
  if [ -f "$NEEDS" ]; then
    r="$(awk -F'\t' -v t="$target" '$1 != "" && ($1 == t || index(t, $1 "/") == 1) { print ($2 == "" ? "理由の記載なし" : $2); exit }' "$NEEDS")"
    [ -z "$r" ] || { printf '精査が確認を要すると判断した（%s）' "$r"; return; }
  fi
  n="$(bash "$CR_SCRIPTS/corrections.sh" count "$SELF_NAME/$kind/$skill" 2>/dev/null)"
  if [ "${n:-0}" -ge 2 ]; then
    printf '同じ種類の変更（%s/%s/%s）が訂正リストで %s 回訂正されている' "$SELF_NAME" "$kind" "$skill" "$n"; return
  fi
  if [ "$kind" != 追加 ]; then
    for p in ${PROTECTED_NAMES[@]+"${PROTECTED_NAMES[@]}"}; do
      if [ "$skill" = "$p" ]; then printf '安全のための規則のスキル（%s）の%sである' "$skill" "$kind"; return; fi
    done
  fi
}

record_change() {
  local kind="$1" target="$2" dfile="$3" skill="$4" more="${5:-}" kr title id x k
  local extra=() c
  kr="$(kind_reason "$target" "$kind" "$skill")"
  title="${target#$ROOT/} の${kind}（skill-audit の精査）"
  for c in ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do extra+=(--allow-root "$c"); done
  extra+=(--allow-root "$ROOT")
  if [ -n "$more" ] && [ -f "$more" ]; then
    while IFS= read -r x; do [ -n "$x" ] && extra+=(--extra-target "$x"); done <"$more"
  fi
  if [ "$kind" = 追加 ]; then
    k=直してよい
    [ -z "$kr" ] || k=要確認
    id="$("$CR_SCRIPTS/new-change.sh" --id-prefix "$SELF_NAME" --kind "$k" --kind-reason "$kr" \
      --source "skill-audit（${RESULT_REPORT}）" --title "$title" --target "$target" \
      --diff-file "$dfile" --reason "skill-audit の精査（${ts}）。根拠は結果 ${RESULT_REPORT} を参照する。")" || return 1
  else
    id="$("$CR_SCRIPTS/propose.sh" --id-prefix "$SELF_NAME" --kind "$kind" \
      --category "$SELF_NAME/$kind/$skill" --kind-reason "$kr" --target "$target" \
      --diff-file "$dfile" --dest-dir "$DEST_BASE$(stage_rel "$target")" "${extra[@]}" \
      --source "skill-audit（${RESULT_REPORT}）" --title "$title" \
      --reason "skill-audit の精査（${ts}）。根拠は結果 ${RESULT_REPORT} を参照する。")" || return 1
  fi
  id="${id%%$'\n'*}"
  k="$(awk -v id="$id" '/^## / { found = ($NF == id) } found && /^- 区分: / { sub(/^- 区分: /, ""); print; exit }' "$CHANGES_LOG")"
  printf -- '- %s・%s・`%s`・%s\n' "$id" "$k" "$target" "$title" >>"$RECORDED"
}

# 削除されたスキルへの参照の修正を、同じ削除の差分にまとめる。
mentioned_deleted_skill() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if tail -n +3 "$1" | grep '^-' | grep -Eq "(^|[^A-Za-z0-9_-])${s}([^A-Za-z0-9_-]|\$)"; then printf '%s\n' "$s"; return 0; fi
  done <"$RUN_DIR/deleted-skills.txt"
  return 1
}

review_changes() {
  local t f rel target before after kind s one="$RUN_DIR/one.diff"
  : >"$RUN_DIR/deleted-skills.txt"
  : >"$RUN_DIR/move-dests.txt"
  find "$DEST_BASE" -name moves.tsv -type f -print | while IFS= read -r f; do
    cut -f1 "$f"
  done | awk 'NF' >"$RUN_DIR/move-dests.txt"
  while IFS= read -r t; do
    if [ ! -d "$STAGE/$t" ]; then
      printf '%s\n' "$t" >>"$RUN_DIR/deleted-skills.txt"
      : >"$RUN_DIR/delete-$t.diff"; : >"$RUN_DIR/delete-$t.targets"
      while IFS= read -r f; do
        [ ! -L "$f" ] || continue
        "$CR_SCRIPTS/diff-label.sh" "$f" /dev/null "$ROOT/${f#$BEFORE/}" >>"$RUN_DIR/delete-$t.diff"
      done < <(find "$BEFORE/$t" -type f -print | LC_ALL=C sort)
    fi
  done <"$RUN_DIR/targets.txt"
  {
    (cd "$BEFORE" && find . \( -type f -o -type l \) -print)
    (cd "$STAGE" && find . \( -type f -o -type l \) -print)
  } | LC_ALL=C sort -u >"$RUN_DIR/files.txt"
  while IFS= read -r rel; do
    rel="${rel#./}"; t="${rel%%/*}"
    case "$rel" in *..*|.*) printf -- '- `%s`: 対象外の相対パスである\n' "$rel" >>"$NOTES"; continue ;; esac
    is_excluded_name "$t" && continue
    if ! grep -Fxq -- "$t" "$RUN_DIR/targets.txt"; then
      if [ -e "$ROOT/$t" ] || [ -L "$ROOT/$t" ]; then
        printf -- '- `%s`: 元のスキル置き場の対象外の項目と同名のため、記録していない\n' "$ROOT/$rel" >>"$NOTES"
        continue
      fi
      if [ ! -d "$STAGE/$t" ] || [ -L "$STAGE/$t" ] || [ ! -f "$STAGE/$t/SKILL.md" ]; then
        printf -- '- `%s`: 新規スキルの非リンクディレクトリと SKILL.md がそろっていないため、記録していない\n' "$ROOT/$rel" >>"$NOTES"
        continue
      fi
    fi
    grep -Fxq -- "$t" "$RUN_DIR/deleted-skills.txt" && continue
    target="$ROOT/$rel"; before="$BEFORE/$rel"; after="$STAGE/$rel"
    if [ -L "$before" ] || [ -L "$after" ]; then
      if [ "$(readlink "$before" 2>/dev/null)" != "$(readlink "$after" 2>/dev/null)" ]; then
        printf -- '- `%s`: シンボリックリンクの変更は記録していない\n' "$target" >>"$NOTES"
      fi
      continue
    fi
    [ -f "$before" ] || before=/dev/null
    [ -f "$after" ] || after=/dev/null
    cmp -s "$before" "$after" && continue
    if grep -Fxq -- "$target" "$RUN_DIR/move-dests.txt"; then
      printf -- '- `%s`: 移し先への追加は行き先の表の差分にまとめるため、作業用での直接の変更を別に記録していない\n' "$target" >>"$NOTES"
      continue
    fi
    "$CR_SCRIPTS/diff-label.sh" "$before" "$after" "$target" >"$one"
    [ $? -eq 1 ] || { printf -- '- `%s`: 差分を作れなかった\n' "$target" >>"$NOTES"; result_rc=1; continue; }
    kind=修正
    if [ "$after" = /dev/null ]; then kind=削除
    elif [ "$before" = /dev/null ] || ! tail -n +3 "$one" | grep -q '^-'; then kind=追加; fi
    if [ "$kind" = 修正 ] && s="$(mentioned_deleted_skill "$one")"; then
      cat "$one" >>"$RUN_DIR/delete-$s.diff"
      printf '%s\n' "$target" >>"$RUN_DIR/delete-$s.targets"
      continue
    fi
    if ! record_change "$kind" "$target" "$one" "$t"; then
      printf -- '- `%s`: 記録への追記に失敗した\n' "$target" >>"$NOTES"; result_rc=1
    fi
  done <"$RUN_DIR/files.txt"
  while IFS= read -r t; do
    if ! record_change 削除 "$ROOT/$t" "$RUN_DIR/delete-$t.diff" "$t" "$RUN_DIR/delete-$t.targets"; then
      printf -- '- `%s`: スキルの削除の記録への追記に失敗した\n' "$ROOT/$t" >>"$NOTES"; result_rc=1
    fi
  done <"$RUN_DIR/deleted-skills.txt"
}

prepare_result() {
  local day n
  RESULT_REPORT="$PUBLIC_REPORT"
  if [ -z "$RESULT_REPORT" ] || [ ! -f "$RESULT_REPORT" ]; then
    mkdir -p "$RESULT_DIR" || return 1
    day="$(date '+%Y-%m-%d')"
    RESULT_REPORT="$RESULT_DIR/$day.md"; n=2
    while [ -e "$RESULT_REPORT" ]; do RESULT_REPORT="$RESULT_DIR/$day-$n.md"; n=$((n + 1)); done
    printf '# skill-audit の結果（%s）\n' "$day" >"$RESULT_REPORT" || return 1
  fi
}

if [ -z "$CR_SCRIPTS" ]; then
  log_error "Skill change-review の scripts が見つかりません。直したいことを記録できないため、精査を起動しません"
  exit 1
fi
mkdir -p "$BEFORE" "$STAGE" "$DEST_BASE" || exit 1
: >"$RECORDED"; : >"$NOTES"
list_targets >"$RUN_DIR/targets.txt"
while IFS= read -r t; do
  # 自作のスキルのリンクは実体を複製する。元のリンクと実体は書き換えない。
  if ! cp -RpH "$ROOT/$t" "$BEFORE/$t" || ! cp -RpH "$ROOT/$t" "$STAGE/$t"; then
    log_error "複製に失敗しました: $ROOT/${t}。精査を起動しません"; exit 1
  fi
done <"$RUN_DIR/targets.txt"
# 古い複製の整理は従来どおり、runs の下だけを対象にする。
ls -1d "$STATE_DIR/runs/"*/ 2>/dev/null | LC_ALL=C sort -r | tail -n +$((RUN_KEEP + 1)) | while IFS= read -r old; do
  rm -rf -- "${old%/}"
done
prepare_result || exit 1
log_info "精査を起動します（hash=${current_hash}）"
print_command
(cd "$STAGE" && "${cmd[@]}")
rc=$?; result_rc="$rc"
if [ "$rc" -eq 0 ]; then
  if [ -f "$RUN_DIR/deletions.tsv" ]; then
    while IFS=$'\t' read -r target reason || [ -n "$target" ]; do
      case "$target" in "$ROOT"/*) rel="${target#$ROOT/}" ;; *) rel="" ;; esac
      case "$rel" in ""|*..*|.*) printf -- '- `%s`: 対象外の削除の候補である\n' "$target" >>"$NOTES"; continue ;; esac
      t="${rel%%/*}"
      check_path="$STAGE/$rel"; linked=0
      while [ "$check_path" != "$STAGE" ]; do
        [ -L "$check_path" ] && linked=1
        check_path="${check_path%/*}"
      done
      if ! grep -Fxq -- "$t" "$RUN_DIR/targets.txt" || [ "$linked" -eq 1 ]; then
        printf -- '- `%s`: 対象外の削除の候補である\n' "$target" >>"$NOTES"; continue
      fi
      # 削除するのは作業用の複製だけである。
      rm -rf -- "$STAGE/$rel"
      [ -z "${reason:-}" ] || printf -- '- `%s`: 削除の候補の理由: %s\n' "$target" "$reason" >>"$NOTES"
    done <"$RUN_DIR/deletions.tsv"
  fi
  review_changes
else
  printf -- '- 精査が異常終了したため（終了コード %s）、記録に足していない\n' "$rc" >>"$NOTES"
fi
{
  printf '\n## 記録に足した直したいこと（ID・区分・対象・要約）\n\n'
  if [ -s "$RECORDED" ]; then cat "$RECORDED"; else printf 'なし\n'; fi
  if [ -s "$NOTES" ]; then printf '\n## 記録しなかった候補と補足\n\n'; cat "$NOTES"; fi
  printf '\n元のスキルと history.md は変更していない。\n'
} >>"$RESULT_REPORT"
log_info "結果を書きました: $RESULT_REPORT"
if [ "$result_rc" -ne 0 ]; then
  log_error "精査または記録が失敗しました（終了コード ${result_rc}）。last-hash は更新しません"
  exit "$result_rc"
fi
new_hash="$(compute_hash)"
printf '%s\n' "$new_hash" >"$STATE_DIR/last-hash"
log_info "精査が完了しました。last-hash を更新しました（hash=${new_hash}）"
exit 0
