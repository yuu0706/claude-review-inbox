#!/bin/bash
# skill-audit を非対話で起動する。launchd から週1回呼ばれる。
# 使い方: run-audit.sh [--force] [--dry-run]
#   --force    変更が無くても起動する
#   --dry-run  起動せず、組み立てたコマンドを標準出力へ表示する。last-hash は更新しない。
# 起動の前に対象のスキル群を STATE_DIR/runs/<日時>/before へ複製し、終わった後に比べる。
# 変更（追加・修正・ファイルの削除・スキルの削除）ごとに承認が要るかを判定し（approval_reason）、要らなければ残す。
# 承認が要るものは実行前の版に戻したうえで、Skill change-review の承認待ちの案にする（案はシェルで作る）。
# 承認が要るのは、claude が needs-approval.tsv に挙げたもの、訂正リストで同じ種類が2回訂正されたもの、
# 安全のための規則のスキル（SKILL_AUDIT_PROTECTED）の修正・削除、安全のための規則の記述を消すもの、移し先への書き足しを伴うものである。
# 承認なしで反映した変更には ID を振り、直す前の版を history/<日付>/ へ複製し、history.md と結果（~/claude-reports/skill-audit/）に載せる。
set -u

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
unset CLAUDE_CONFIG_DIR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib.sh"
# 利用者の環境だけの決まりを書く上書きファイル。SKILL.md より優先して読ませる。
OVERRIDE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-skills/$SELF_NAME.local.md"

# 承認待ちの置き場所・否認リスト・判断の台帳（claude-review-inbox）。
PROPOSALS_DIR="${CLAUDE_REVIEW_PROPOSALS:-${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals}"
PROPOSALS_DIR="${PROPOSALS_DIR%/}"
REJECTIONS="$PROPOSALS_DIR/rejections.md"
CORRECTIONS="$PROPOSALS_DIR/corrections.md"
# 結果（未読の知らせに出るもの）の置き場所。公開版の点検（check-public.sh）と同じ場所に書く。
RESULT_DIR="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
RESULT_DIR="${RESULT_DIR%/}/$SELF_NAME"
# 修正・削除を常に承認待ちに回すスキル（安全のための規則）。空白区切り。
[ -n "${SKILL_AUDIT_PROTECTED:-}" ] || SKILL_AUDIT_PROTECTED="$(jobs_conf SKILL_AUDIT_PROTECTED)"
read -r -a PROTECTED_NAMES <<<"${SKILL_AUDIT_PROTECTED:-security-rules commit-guard}"
# 差分の - 行がこれに当たる変更は、安全のための規則をゆるめるおそれがあるため、承認待ちに回す。
SAFETY_RE='permissions\.deny|gitleaks|秘密の検査'
LEDGER_DIR="${CLAUDE_REVIEW_STATE:-$HOME/.local/state/claude-review-inbox}"
LEDGER_DIR="${LEDGER_DIR%/}"
# snapshot.sh と trash-skill.sh は、スキル置き場を経由した絶対パスで呼ばせる（許可の規則と一致させるため）。
SCRIPTS_CALL="$ROOT/$SELF_NAME/scripts"
PROMPT="Skill skill-audit を自動モードで実行する。対象範囲と手順は SKILL.md に従う。否認リストは ${REJECTIONS} にある。始める前に読み、否認リストと同じ対象・同じ趣旨の修正・削除は行わない。訂正リストは ${CORRECTIONS} にある。否認リストと同じく始める前に読み、訂正された変更を再び行わない。複製は ${SCRIPTS_CALL}/snapshot.sh、スキルの削除は ${SCRIPTS_CALL}/trash-skill.sh を、この絶対パスのとおりに呼ぶ（相対パスや別の表記で呼ばない）。変更の記録は ${HISTORY_FILE} に書く。直す前の複製は snapshot.sh が ${HISTORY_DIR}/<日付>/ に置く。利用者の環境だけの決まりは ${OVERRIDE_FILE} にある（無ければ飛ばす）。"
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
APPROVAL_MODE="$(approval_mode)"
LEDGER_SH=""
for lsc in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" "$ROOT/change-review/scripts"; do
  [ -n "$lsc" ] && [ -f "$lsc/ledger.sh" ] && { LEDGER_SH="$lsc/ledger.sh"; break; }
done
link_reals=()
while IFS= read -r lr; do [ -n "$lr" ] && link_reals+=("$lr"); done < <(skill_link_reals "$ROOT" ${SKILL_DIRS[@]+"${SKILL_DIRS[@]}"})

# Skill change-review の scripts を探す。スキル置き場の change-review を経由し、リポジトリの絶対パスを埋め込まない。
find_change_review() {
  local c
  for c in "${CHANGE_REVIEW_SCRIPTS:-}" "$(dirname "$0")/../../change-review/scripts" \
    "$ROOT/change-review/scripts" ${SKILL_DIRS[@]+"${SKILL_DIRS[@]/%//change-review/scripts}"}; do
    if [ -n "$c" ] && [ -x "$c/new-proposal.sh" ] && [ -x "$c/diff-label.sh" ] && [ -x "$c/propose.sh" ]; then
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
# 修正・削除の候補ごとの「消える記述の行き先」を claude に書かせる場所（Skill change-review の destinations.sh が読む）。
DEST_BASE="$RUN_DIR/destinations"
# 承認が要ると claude が判断した変更の一覧（対象の絶対パス<TAB>理由）。
NEEDS="$RUN_DIR/needs-approval.tsv"
PROMPT="${PROMPT}承認が要らないと判断した修正・削除・統合は、そのまま残る。承認が要ると判断したもの（SKILL.md「1.1」の承認待ちに回すもの、判断に迷うもの）は、${NEEDS} に「対象の絶対パス<TAB>理由」の形で1行1件書く（ファイルならファイルの、スキルの削除ならスキルのディレクトリの絶対パス。シェルが実行前の版へ戻して承認待ちにする）。"
CR_SCRIPTS="$(find_change_review)" || CR_SCRIPTS=""
if [ -n "$CR_SCRIPTS" ]; then
  PROMPT="${PROMPT}承認待ちにする修正・削除は、実行後に実行前の版へ戻して承認待ちの案にする。スキルの削除では、スキルのディレクトリの絶対パスを候補とする。スキルを削除する場合、そのスキルを参照する他の箇所の修正も同じ実行の中で行う（シェルが削除の案にまとめる）。移し先へ書き足す内容は、移し先のファイルを直接直さず、次の規則のとおり行き先のフォルダに置く。
$("$CR_SCRIPTS/destinations.sh" --print-rule "$DEST_BASE")"
fi

# 許可する規則。読んでよい範囲を設定ディレクトリ（スキル・メモリ）・結果の置き場所と ROOT に限る。
# 範囲を付けない Read・Glob・Grep と、任意のパスを読める Bash（ls・grep・diff 等）は許可しない。
# ホームの下の同期フォルダ等を検索すると、macOS がアクセス許可のダイアログを出すためである。
read_scopes=(${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"} "$HOME/.agents" "$HOME/claude-reports" "$HOME/.local/state/claude-reports"
  "$ROOT" "$PROPOSALS_DIR" "$DEST_BASE" "$HISTORY_DIR")
# 変更の記録はスキル置き場の外（STATE_DIR）にあるため、そのファイルだけ読み書きを許可する。
allowed=(Skill "Bash(date:*)" "Edit(/$ROOT/**)" "Edit(/$DEST_BASE/**)" "Edit(/$NEEDS)" "Read(/$HISTORY_FILE)" "Edit(/$HISTORY_FILE)" "Read(/$OVERRIDE_FILE)")
# snapshot.sh と trash-skill.sh は、実体のパス・スキル置き場を経由したパス・作業のフォルダ（ROOT）からの相対パスの各形を許可する。
# Bash の許可は文字列の前方一致で判定されるため、リンクの側のパスで呼ぶと実体のパスの規則に一致せず、許可待ちで止まる。
seen_bash=" "
for sc in snapshot.sh trash-skill.sh; do
  for sp in "$SCRIPT_DIR/$sc" "$ROOT/$SELF_NAME/scripts/$sc" \
    ${SKILL_DIRS[@]+"${SKILL_DIRS[@]/%//$SELF_NAME/scripts/$sc}"} "$SELF_NAME/scripts/$sc" "./$SELF_NAME/scripts/$sc"; do
    case "$seen_bash" in *" $sp "*) continue ;; esac
    seen_bash="$seen_bash$sp "
    allowed+=("Bash($sp:*)")
  done
done
for d in "${read_scopes[@]}"; do allowed+=("Read(/$d/**)"); done
for lr in ${link_reals[@]+"${link_reals[@]}"}; do allowed+=("Read(/$lr/**)"); done
# 自作のスキルのリンク（is_own_link）は、実体のパスでも書き換えを許可する。
own_reals=" "
while IFS= read -r n; do
  is_target "$n" || continue
  real="$(resolve_link "$ROOT/$n")"
  [ -n "$real" ] || continue
  case "$own_reals" in *" $real "*) continue ;; esac
  own_reals="$own_reals$real "
  allowed+=("Edit(/$real/**)")
done < <(list_symlinks)

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
add_deny "Edit(/$HOME/.agents/**)"
add_deny "Edit(/$HOME/Documents/**)"
deny_files=()
for c in ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do deny_files+=("$c/CLAUDE.md" "$c/settings.json"); done
for df in ${deny_files[@]+"${deny_files[@]}"}; do add_deny "Edit(/$df)"; done
add_deny "Edit(/$PROPOSALS_DIR/**)"
add_deny "Edit(/$LEDGER_DIR/**)"
# CLAUDE.md・settings.json・承認待ちの置き場所・台帳がリンクなら（別の設定ディレクトリの CLAUDE.md へのリンク等）、実体のパスでも拒否する。
for df in ${deny_files[@]+"${deny_files[@]}"} "$PROPOSALS_DIR" "$LEDGER_DIR"; do
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
  printf "cd '%s' &&" "${ROOT//\'/$sq}"
  for a in "${cmd[@]}"; do
    printf " '%s'" "${a//\'/$sq}"
  done
  printf '\n'
}

if [ "$dry_run" -eq 1 ]; then
  print_command
  exit 0
fi

# ---- 実行前の複製と、実行後の比較 ----

# 既存の行を変えない・消さない変更（diff の - 行が無い）なら 0 を返す。
only_additions() {
  ! diff -u "$1" "$2" | tail -n +3 | grep -q '^-'
}

# 見出しを対象の絶対パスにした差分を出す。change-review が無ければ diff -u のまま出す（承認待ちは作られない）。
label_diff() {
  if [ -n "$CR_SCRIPTS" ]; then
    "$CR_SCRIPTS/diff-label.sh" "$@"
  else
    diff -u -- "$1" "$2"
  fi
}

# 承認待ちの案を1件作り、番号を PROPOSED に記録する。
# 行き先の表は claude が書いた DEST_BASE<対象の位置>/ から読み、移し先への追加の差分も同じ案に入れる（Skill change-review の propose.sh）。
# 引数: <修正|削除> <対象の絶対パス> <差分のファイル> <短い名前> <理由> [<反映後の確かめ方>] [<差分に含めた他の対象の一覧のファイル>]
make_proposal() {
  local kind="$1" target="$2" dfile="$3" slug="$4" reason="$5" check="${6:-}" more="${7:-}" id x
  local extra=() c
  for c in ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do extra+=(--allow-root "$c"); done
  extra+=(--allow-root "$ROOT")
  if [ -z "$CR_SCRIPTS" ]; then
    printf -- '- `%s`（%s）: Skill change-review が見つからず承認待ちを作れなかった。実行前の版に戻した\n' "$target" "$kind" >>"$NOTES"
    return 1
  fi
  if [ -n "$more" ] && [ -f "$more" ]; then
    while IFS= read -r x; do [ -n "$x" ] && extra+=(--extra-target "$x"); done <"$more"
  fi
  id="$("$CR_SCRIPTS/propose.sh" --kind "$kind" --target "$target" --diff-file "$dfile" \
    --dest-dir "$DEST_BASE$(stage_rel "$target")" "${extra[@]}" --source "skill-audit（自動の精査 ${ts}）" \
    --title "${target#$ROOT/} の${kind}（skill-audit の自動の精査）" \
    --slug "$slug" --reason "$reason" --check "${check:-対象のファイルが差分のとおりになっていること、参照しているスキル名と節の名前が実在すること、移し先へ書き足されていることを確かめる。}")"
  if [ -z "$id" ]; then
    printf -- '- `%s`（%s）: 承認待ちの作成に失敗した。実行前の版に戻した\n' "$target" "$kind" >>"$NOTES"
    return 1
  fi
  printf -- '- %s: `%s`（%s）\n' "${id%%$'\n'*}" "$target" "$kind" >>"$PROPOSED"
}

# 差分の - 行が、承認待ちに回したスキルの削除の対象の名前を含めば、そのスキルの名前を出す。
mentioned_deleted_skill() {
  local s
  [ -s "$RUN_DIR/delete-approval.txt" ] || return 1
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if tail -n +3 "$1" | grep '^-' | grep -Eq "(^|[^A-Za-z0-9_-])${s}([^A-Za-z0-9_-]|\$)"; then
      printf '%s\n' "$s"
      return 0
    fi
  done <"$RUN_DIR/delete-approval.txt"
  return 1
}

# 承認が要るかを判定する。要れば理由を標準出力へ書いて 0 を返し、要らなければ 1 を返す。
# 引数: <対象の絶対パス> <追加|修正|削除> <スキル名> <差分のファイル>
approval_reason() {
  local target="$1" kind="$2" skill="$3" dfile="$4" ddir n r p
  ddir="$DEST_BASE$(stage_rel "$target")"
  if [ -z "$CR_SCRIPTS" ]; then
    # 訂正リストを読めず、承認待ちも作れない。追加だけは従来どおり残す。
    [ "$kind" = 追加 ] && return 1
    printf 'Skill change-review が見つからない'
    return 0
  fi
  if [ -f "$NEEDS" ]; then
    # 対象そのもの、または対象を含むスキルのディレクトリが挙がっていれば、承認待ちにする。
    r="$(awk -F'\t' -v t="$target" '$1 != "" && ($1 == t || index(t, $1 "/") == 1) { print ($2 == "" ? "理由の記載なし" : $2); exit }' "$NEEDS")"
    if [ -n "$r" ]; then
      printf '精査が承認が要ると判断した（%s）' "$r"
      return 0
    fi
  fi
  n="$(bash "$CR_SCRIPTS/corrections.sh" count "$SELF_NAME/${kind}/${skill}" 2>/dev/null)"
  if [ "${n:-0}" -ge 2 ]; then
    printf '同じ種類の変更（%s/%s/%s）が訂正リストで %s 回訂正されている' "$SELF_NAME" "$kind" "$skill" "$n"
    return 0
  fi
  if [ "$kind" != 追加 ]; then
    for p in ${PROTECTED_NAMES[@]+"${PROTECTED_NAMES[@]}"}; do
      if [ "$skill" = "$p" ]; then
        printf '安全のための規則のスキル（%s）の%sである' "$skill" "$kind"
        return 0
      fi
    done
  fi
  if [ -s "$dfile" ] && tail -n +3 "$dfile" | grep '^-' | grep -Eq "$SAFETY_RE"; then
    printf '安全のための規則（permissions.deny・gitleaks・秘密の検査など）の記述を消す・変える'
    return 0
  fi
  if [ -f "$ddir/moves.tsv" ] || grep -Fq '（候補なし）' "$ddir/table.md" 2>/dev/null; then
    printf '消える記述を移し先へ書き足す必要がある'
    return 0
  fi
  if [ "$APPROVAL_MODE" = screen ] && [ "$kind" != 追加 ]; then
    printf '承認ありの設定（CLAUDE_REVIEW_APPROVAL_MODE=screen）では、修正と削除をすべて承認待ちにする'
    return 0
  fi
  return 1
}

# 直す前の版を history/<日付>/ へ複製し、そのパスを出す（snapshot.sh と同じ名前の付け方。既にあれば最初の版を残す）。
# 引数: <実行前の版> <スキル内の相対パスを含む、ROOT からの相対パス>
keep_before() {
  local src="$1" rel="$2" skill rest dest
  skill="${rel%%/*}"
  rest="${rel#*/}"
  dest="$HISTORY_DIR/$(date '+%Y-%m-%d')/${skill}__${rest//\//_}.bak"
  mkdir -p "${dest%/*}" || return 1
  [ -e "$dest" ] || cp -p "$src" "$dest" || return 1
  printf '%s\n' "$dest"
}

# 承認なしで反映した変更を1件記録する。変更の台帳（Skill change-review の ledger.sh）にも直す前と直した後の版を写す。
# 引数: <追加|修正|削除> <対象の絶対パス> <スキル名> <戻し方> <直す前の版|-> [<直した後の版|->（省略時は対象の今の状態）]
record_auto() {
  local n id after="${6:-$2}"
  n="$(cat "$RUN_DIR/auto-n" 2>/dev/null || echo 0)"
  n=$((n + 1))
  printf '%s\n' "$n" >"$RUN_DIR/auto-n"
  id="$(printf '%s-%s-%02d' "$SELF_NAME" "${RUN_DIR##*/}" "$n")"
  printf -- '- %s: `%s`（%s。種類 `%s/%s/%s`。%s）\n' "$id" "$2" "$1" "$SELF_NAME" "$1" "$3" "$4" >>"$ADDED"
  if [ -z "$LEDGER_SH" ]; then
    printf -- '- %s: 変更の台帳（ledger.sh）が見つからず、台帳に記録できなかった\n' "$id" >>"$NOTES"
  elif ! bash "$LEDGER_SH" record --id "$id" --kind "$SELF_NAME/$1/$3" --target "$2" --before "${5:--}" --after "$after" >/dev/null; then
    printf -- '- %s: 変更の台帳への記録に失敗した\n' "$id" >>"$NOTES"
  fi
}

# スキルが消えたかを判定する。
skill_gone() {
  [ ! -d "$ROOT/$1" ] || { [ -L "$ROOT/$1" ] && ! is_own_link "$1"; }
}

# 実行の前後を比べ、追加は残し、修正・削除は戻して承認待ちにする。
# スキルの削除と、そのスキルを参照する他の箇所の修正（差分の - 行がスキルの名前を含むもの）は、1件の案にまとめる。
# 行き先の表の移し先（moves.tsv）に挙がったファイルを claude が直接書き換えていたら、実行前の版に戻す（移し先への追加は案で行う）。
review_changes() {
  local t f rel cur one trashed e dels s r kind
  one="$RUN_DIR/one.diff"
  : >"$RUN_DIR/deleted-skills.txt"
  : >"$RUN_DIR/move-dests.txt"
  if [ -d "$DEST_BASE" ]; then
    find "$DEST_BASE" -name moves.tsv -type f -print | while IFS= read -r f; do
      cut -f1 "$f"
    done | awk 'NF' >"$RUN_DIR/move-dests.txt"
  fi
  : >"$RUN_DIR/delete-approval.txt"
  while IFS= read -r t; do
    [ -n "$t" ] && skill_gone "$t" || continue
    printf '%s\n' "$t" >>"$RUN_DIR/deleted-skills.txt"
    # スキルが消えた（trash-skill.sh で移された）。承認が要るかを判定し、要るものだけ元に戻す。
    trashed=""
    for e in "$ROOT/.skill-audit-trash/"*-"$t"; do
      [ -d "$e" ] || continue
      grep -Fxq -- "$e" "$RUN_DIR/trash-before.txt" && continue
      trashed="$e"
    done
    dels="$RUN_DIR/delete-$t.self.diff"
    : >"$dels"
    (cd "$BEFORE/$t" && find . \( -type f -o -type l \) -print | LC_ALL=C sort) | while IFS= read -r rel; do
      rel="${rel#./}"
      label_diff "$BEFORE/$t/$rel" /dev/null "$ROOT/$t/$rel" >>"$dels"
    done
    if r="$(approval_reason "$ROOT/$t" 削除 "$t" "$dels")"; then
      printf '%s\n' "$t" >>"$RUN_DIR/delete-approval.txt"
      printf '%s\n' "$r" >"$RUN_DIR/delete-$t.reason"
      : >"$RUN_DIR/delete-$t.refs.diff"
      : >"$RUN_DIR/delete-$t.targets"
      if [ ! -e "$ROOT/$t" ] && [ ! -L "$ROOT/$t" ]; then
        if [ -n "$trashed" ]; then mv "$trashed" "$ROOT/$t"; else cp -Rp "$BEFORE/$t" "$ROOT/$t"; fi
        log_info "削除されたスキルを戻しました: $t"
      fi
    else
      # 承認なしで残す。直す前の版は、退避先（.skill-audit-trash）に加えて history/<日付>/ にも複製する。
      e="$HISTORY_DIR/$(date '+%Y-%m-%d')/${t}__skill"
      [ -e "$e" ] || { mkdir -p "${e%/*}" && cp -Rp "$BEFORE/$t" "$e"; }
      if [ -n "$trashed" ]; then
        record_auto 削除 "$ROOT/$t" "$t" "退避先 \`$trashed\`、直す前の版 \`$e\`" "$BEFORE/$t" -
      else
        record_auto 削除 "$ROOT/$t" "$t" "直す前の版 \`$e\`" "$BEFORE/$t" -
      fi
    fi
  done <"$RUN_DIR/targets.txt"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # 消えたスキルは上で扱った。承認待ちの案は、参照している箇所の修正を集めた後（このループの後）に作る。
    grep -Fxq -- "$t" "$RUN_DIR/deleted-skills.txt" && continue
    (cd "$BEFORE/$t" && find . \( -type f -o -type l \) -print | LC_ALL=C sort) | while IFS= read -r rel; do
      rel="$t/${rel#./}"
      f="$BEFORE/$rel"
      cur="$ROOT/$rel"
      if [ -L "$f" ] || [ -L "$cur" ]; then
        if [ "$(readlink "$f" 2>/dev/null)" != "$(readlink "$cur" 2>/dev/null)" ]; then
          rm -f "$cur" && mkdir -p "$(dirname "$cur")" && cp -Pp "$f" "$cur"
          printf -- '- `%s`: シンボリックリンクが変わったため、実行前の状態に戻した（承認待ちは作っていない）\n' "$cur" >>"$NOTES"
        fi
      elif [ ! -e "$cur" ]; then
        label_diff "$f" /dev/null "$cur" >"$one"
        if r="$(approval_reason "$cur" 削除 "$t" "$one")"; then
          mkdir -p "$(dirname "$cur")" && cp -p "$f" "$cur"
          make_proposal 削除 "$cur" "$one" "skill-audit-delete" \
            "skill-audit の自動の精査（${ts}）がファイルを削除した。承認待ちに回した理由: ${r}。実行前の版に戻した。"
        else
          record_auto 削除 "$cur" "$t" "直す前の版 \`$(keep_before "$f" "$rel")\`" "$f" -
        fi
      elif cmp -s "$f" "$cur"; then
        :
      elif grep -Fxq -- "$cur" "$RUN_DIR/move-dests.txt"; then
        cp -p "$f" "$cur"
        printf -- '- `%s`: 行き先の表の移し先を直接書き換えていたため、実行前の版に戻した（移し先への追加は案の差分で行う）\n' "$cur" >>"$NOTES"
      else
        kind=修正
        only_additions "$f" "$cur" && kind=追加
        label_diff "$f" "$cur" "$cur" >"$one"
        if [ "$kind" = 修正 ] && s="$(mentioned_deleted_skill "$one")"; then
          # 承認待ちに回したスキルの削除の対象を参照する箇所の修正は、スキルの削除の案に入れる。
          cp -p "$f" "$cur"
          cat "$one" >>"$RUN_DIR/delete-$s.refs.diff"
          printf '%s\n' "$cur" >>"$RUN_DIR/delete-$s.targets"
          continue
        fi
        if r="$(approval_reason "$cur" "$kind" "$t" "$one")"; then
          cp -p "$f" "$cur"
          make_proposal 修正 "$cur" "$one" "skill-audit-edit" \
            "skill-audit の自動の精査（${ts}）が${kind}を行った。承認待ちに回した理由: ${r}。実行前の版に戻した。根拠は ${HISTORY_FILE} の同じ日時の記録を参照する。"
        else
          record_auto "$kind" "$cur" "$t" "直す前の版 \`$(keep_before "$f" "$rel")\`" "$f"
        fi
      fi
    done
    # 新しいファイルは追加として残す。
    (cd "$ROOT/$t" && find . \( -type f -o -type l \) -print | LC_ALL=C sort) | while IFS= read -r rel; do
      rel="$t/${rel#./}"
      [ -e "$BEFORE/$rel" ] || [ -L "$BEFORE/$rel" ] || record_auto 追加 "$ROOT/$rel" "$t" "新しいファイル。消せば戻る" -
    done
  done <"$RUN_DIR/targets.txt"
  # 承認待ちに回したスキルの削除の案を作る。参照している箇所の修正も同じ案に入れる。
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    cat "$RUN_DIR/delete-$t.self.diff" "$RUN_DIR/delete-$t.refs.diff" >"$RUN_DIR/delete-$t.diff"
    make_proposal 削除 "$ROOT/$t" "$RUN_DIR/delete-$t.diff" "skill-audit-delete-$t" \
      "skill-audit の自動の精査（${ts}）がスキル ${t} を削除した。承認待ちに回した理由: $(cat "$RUN_DIR/delete-$t.reason")。実行前の状態に戻した。差分はスキルの全ファイルの削除であり、承認されるとそのまま反映し、空になったフォルダも消す（直す前の版は反映する側が残す）。${t} を参照している他の箇所の修正も、この案の差分に含めた。" \
      "スキル置き場から ${t} が消えていること、${t} を参照しているスキルと CLAUDE.md が残っていないことを確かめる。" \
      "$RUN_DIR/delete-$t.targets"
  done <"$RUN_DIR/delete-approval.txt"
  # 新しいスキルは追加として残す。
  while IFS= read -r t; do
    grep -Fxq -- "$t" "$RUN_DIR/targets.txt" || record_auto 追加 "$ROOT/$t" "$t" "新しいスキル。trash-skill.sh で退避すれば戻る" -
  done < <(list_targets)
}

# history.md の先頭（冒頭の説明の後の --- の次）へ、承認なしで反映した変更と承認待ちの番号を足す。
# 同じ内容を結果（~/claude-reports/skill-audit/）にも書き、未読の知らせに出す。
record_history() {
  local hist="$HISTORY_FILE" n_added n_prop ids tmp
  n_added="$(grep -c '^- ' "$ADDED" | tr -d ' ')"
  n_prop="$(grep -c . "$PROPOSED" | tr -d ' ')"
  [ "$n_added" -gt 0 ] || [ "$n_prop" -gt 0 ] || [ -s "$NOTES" ] || return 0
  ids="$(sed -n 's/^- \([0-9-]*\): .*/\1/p' "$PROPOSED" | tr '\n' ' ' | sed 's/ $//; s/ /、/g')"
  tmp="$RUN_DIR/history.md.tmp"
  write_result "$n_added" "$n_prop" "$ids"
  {
    printf '## %s 自動（run-audit.sh の記録）\n\n' "$(date '+%Y-%m-%d %H:%M')"
    printf -- '- 承認なしで反映した変更: %s件\n' "$n_added"
    sed 's/^/  /' "$ADDED"
    printf -- '- 承認待ちにした変更: %s件（%s）。実行前の版に戻した（Skill change-review、置き場所 %s）\n' "$n_prop" "${ids:-なし}" "$PROPOSALS_DIR"
    sed 's/^/  /' "$PROPOSED"
    if [ -s "$NOTES" ]; then
      printf -- '- 注意\n'
      sed 's/^/  /' "$NOTES"
    fi
    printf '\n'
  } >"$RUN_DIR/record.md"
  # 初めて書くときは、冒頭の説明と区切りを作ってから記録を足す。
  if [ ! -s "$hist" ]; then
    printf '# スキルの変更履歴\n\nSkill skill-audit が行った変更の記録。新しいものを上に書く。\n\n---\n\n' >"$hist"
  fi
  if [ -f "$hist" ] && grep -qx -- '---' "$hist"; then
    awk -v rec="$RUN_DIR/record.md" '
      !done && $0 == "---" { print; print ""; while ((getline l < rec) > 0) print l; done = 1; skip = 1; next }
      skip && $0 == "" { skip = 0; next }
      { skip = 0; print }' "$hist" >"$tmp" && cat "$tmp" >"$hist"
  else
    cat "$RUN_DIR/record.md" >>"$hist"
  fi
  rm -f "$tmp"
  log_info "history.md に記録しました（追加 ${n_added}件、承認待ち ${n_prop}件）"
}

# 結果のファイルへ「承認なしで反映した変更と承認待ち」の節を書く。公開版の点検が同じ実行で結果を
# 書いていれば、そのファイルへ足す。無ければ <日付>.md（同じ日の2回目以降は -2、-3）を作る。
write_result() {
  local n_added="$1" n_prop="$2" ids="$3" report="$PUBLIC_REPORT" day n
  if [ -z "$report" ] || [ ! -f "$report" ]; then
    mkdir -p "$RESULT_DIR" || return 1
    day="$(date '+%Y-%m-%d')"
    report="$RESULT_DIR/$day.md"
    n=2
    while [ -e "$report" ]; do report="$RESULT_DIR/$day-$n.md"; n=$((n + 1)); done
    printf '# skill-audit の結果（%s）\n' "$day" >"$report" || return 1
  fi
  {
    printf '\n## 承認なしで反映した変更と承認待ち\n\n'
    printf '自動の精査（%s）が承認なしで反映した変更 %s件 / 承認待ちにした変更 %s件（%s）（スクリプトが書いた）。\n' "$ts" "$n_added" "$n_prop" "${ids:-なし}"
    if [ "$n_added" -gt 0 ]; then
      printf '戻すときは、Skill change-review の scripts/revert.sh に ID を渡す（変更の台帳 %s から直す前の版を戻す）。' "$(bash "${LEDGER_SH:-/dev/null}" path 2>/dev/null)"
      printf '誤りだった場合は、Skill change-review の「8. 訂正」の手順で直し、訂正リスト（%s）に ID と「正しくは○○」を書く。\n\n' "$CORRECTIONS"
      cat "$ADDED"
    fi
    if [ "$n_prop" -gt 0 ]; then
      printf '\n### 承認待ちにした変更\n\n'
      cat "$PROPOSED"
    fi
    if [ -s "$NOTES" ]; then
      printf '\n## 注意\n\n'
      cat "$NOTES"
    fi
  } >>"$report"
  log_info "結果を書きました: ${report}"
}

BEFORE="$RUN_DIR/before"
ADDED="$RUN_DIR/added.txt"
PROPOSED="$RUN_DIR/proposed.txt"
NOTES="$RUN_DIR/notes.txt"
if [ -z "$CR_SCRIPTS" ]; then
  log_error "Skill change-review の scripts が見つかりません。修正・削除は戻しますが、承認待ちは作れません"
fi
if ! mkdir -p "$BEFORE"; then
  log_error "複製の置き場所を作れません: ${BEFORE}。精査を起動しません"
  exit 1
fi
: >"$ADDED"; : >"$PROPOSED"; : >"$NOTES"
list_targets >"$RUN_DIR/targets.txt"
while IFS= read -r t; do
  # -H で、自作のスキルのリンクは実体の中身を複製する（中のリンクはリンクのまま複製する）。
  if ! cp -RpH "$ROOT/$t" "$BEFORE/$t"; then
    log_error "複製に失敗しました: $ROOT/${t}。精査を起動しません"
    exit 1
  fi
done <"$RUN_DIR/targets.txt"
: >"$RUN_DIR/trash-before.txt"
for e in "$ROOT/.skill-audit-trash/"*; do
  [ -e "$e" ] && printf '%s\n' "$e" >>"$RUN_DIR/trash-before.txt"
done
# 古い複製を RUN_KEEP 件まで減らす。削除してよいのは runs の下だけである。
ls -1d "$STATE_DIR/runs/"*/ 2>/dev/null | LC_ALL=C sort -r | tail -n +$((RUN_KEEP + 1)) | while IFS= read -r old; do
  rm -rf -- "${old%/}"
done

log_info "精査を起動します（hash=${current_hash}）"
print_command
(cd "$ROOT" && "${cmd[@]}")
rc=$?

review_changes
record_history

if [ "$rc" -ne 0 ]; then
  log_error "精査が異常終了しました（終了コード ${rc}）。last-hash は更新しません"
  exit "$rc"
fi

new_hash="$(compute_hash)"
printf '%s\n' "$new_hash" >"$STATE_DIR/last-hash"
log_info "精査が完了しました。last-hash を更新しました（hash=${new_hash}）"
exit 0
