#!/bin/bash
# claude-review-inbox を入れる・外す。何回実行しても結果は同じになる。
# 使い方: ./install.sh [--with-local] [--with-schedule | --no-schedule] [--dry-run] [--uninstall]
#   --with-local     作成者の環境用の連携部分（local/skills/*）と、その3つの定期実行も入れる。棚卸し（review-loop のスキルと定期実行）は入れない
#   --with-schedule  週1回の棚卸し（review-loop）を聞かずに登録する
#   --no-schedule    棚卸しを登録しない（登録済みなら外す）
#   --dry-run     何も変えず、行う操作を表示する
#   --uninstall   launchd から外し、このリポジトリを指すリンクと足したフックを消す
# 環境変数:
#   CLAUDE_REVIEW_LABEL   launchd のラベル（既定 com.<ユーザー名>.claude-review-inbox。ユーザー名のドットはハイフンに置き換える）
#   CLAUDE_REVIEW_PORT    画面のポート（既定 8010）
#   CLAUDE_REVIEW_PYTHON  サーバーを動かす Python（既定 /usr/bin/python3）
#   CLAUDE_REVIEW_LOOP_WEEKDAY / _HOUR / _MINUTE  棚卸しの曜日・時・分（既定 1 / 10 / 0。毎週月曜 10:00）
#   CLAUDE_REVIEW_LOOP_MODEL / _EFFORT            棚卸しの claude に渡す --model / --effort（既定は付けない）
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
with_local=0
dry_run=0
uninstall=0
schedule_opt=""
for arg in "$@"; do
  case "$arg" in
    --with-local) with_local=1 ;;
    --dry-run) dry_run=1 ;;
    --uninstall) uninstall=1 ;;
    --with-schedule|--no-schedule)
      if [ -n "$schedule_opt" ] && [ "$schedule_opt" != "$arg" ]; then
        printf 'ERROR: --with-schedule と --no-schedule は同時に指定できません\n' >&2
        exit 2
      fi
      schedule_opt="$arg"
      ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) printf 'ERROR: 不明な引数です: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$with_local" -eq 1 ] && [ ! -d "$REPO/local/skills" ]; then
  printf 'ERROR: この版には local がありません。本体だけを入れる場合は --with-local を外してください\n' >&2
  exit 2
fi

user_name="$(id -un)"
uid="$(id -u)"
LABEL="${CLAUDE_REVIEW_LABEL:-com.${user_name//./-}.claude-review-inbox}"
PORT="${CLAUDE_REVIEW_PORT:-8010}"
PYTHON="${CLAUDE_REVIEW_PYTHON:-/usr/bin/python3}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.local/state/claude-review-inbox"
PROPOSALS_DIR="$HOME/claude-reports/proposals"
HOOK_CMD="$REPO/core/hooks/session-start.sh"
TS="$(date '+%Y%m%d-%H%M%S')"
AGENTS_DIR="$HOME/Library/LaunchAgents"
# install.sh が登録した定期実行の台帳。1行に「ジョブ名<TAB>ラベル<TAB>plist<TAB>引き継いだなら1」。
JOBS_FILE="$STATE_DIR/scheduled-jobs.tsv"
LABEL_PREFIX="com.${user_name//./-}"
LOOP_WEEKDAY="${CLAUDE_REVIEW_LOOP_WEEKDAY:-1}"
LOOP_HOUR="${CLAUDE_REVIEW_LOOP_HOUR:-10}"
LOOP_MINUTE="${CLAUDE_REVIEW_LOOP_MINUTE:-0}"
# local の定期実行: <ジョブ名>:<起動スクリプト>
LOCAL_JOBS="memory-audit:run.sh feedback-mining:run.sh skill-audit:run-audit.sh"

info() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# 変更を伴う操作。--dry-run では表示だけにする。
run() {
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run]'
    printf ' %s' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# パスの実体（シンボリックリンクを解決した絶対パス）を出す。存在しなければ親を解決して名前を足す。
real_path() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd -P "$p" && pwd -P)
  elif [ -L "$p" ] || [ -e "$p" ]; then
    local dir
    dir="$(cd -P "$(dirname "$p")" && pwd -P)"
    local base
    base="$(basename "$p")"
    if [ -L "$p" ]; then
      local t
      t="$(readlink "$p")"
      case "$t" in
        /*) real_path "$t" ;;
        *) real_path "$dir/$t" ;;
      esac
    else
      printf '%s/%s\n' "$dir" "$base"
    fi
  else
    printf '%s\n' "$p"
  fi
}

# 設定ディレクトリ: ~/.claude と、存在すれば ~/.claude2。
config_dirs=("$HOME/.claude")
[ -d "$HOME/.claude2" ] && config_dirs+=("$HOME/.claude2")

# スキル置き場の実体を、重複を除いて並べる。
skill_dirs=()
seen=" "
for c in "${config_dirs[@]}"; do
  d="$c/skills"
  if [ -e "$d" ] || [ -L "$d" ]; then
    r="$(real_path "$d")"
  else
    r="$d"
  fi
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "
  skill_dirs+=("$r")
done

# settings.json の実体を、重複を除いて並べる。
settings_files=()
seen=" "
for c in "${config_dirs[@]}"; do
  f="$c/settings.json"
  if [ -L "$f" ] || [ -e "$f" ]; then
    r="$(real_path "$f")"
  else
    r="$f"
  fi
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "
  settings_files+=("$r")
done

# 入れるスキルの元のディレクトリ。
skill_sources=()
# --with-local のときは review-loop を入れない。local の3つが同じ役目を持ち、一覧に残ると選び間違えるためである。
for s in "$REPO"/core/skills/*/; do
  [ "$with_local" -eq 1 ] && [ "$(basename "$s")" = "review-loop" ] && continue
  skill_sources+=("${s%/}")
done
if [ "$with_local" -eq 1 ]; then
  for s in "$REPO"/local/skills/*/; do skill_sources+=("${s%/}"); done
fi

# 登録済みなら launchd から外す。--dry-run では launchctl を一切呼ばず、行う操作だけを表示する。
# 引数: [ラベル]（省略時はサーバーのラベル）
bootout_if_registered() {
  local label="${1:-$LABEL}"
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] （登録済みなら）launchctl bootout gui/%s/%s\n' "$uid" "$label"
    return 0
  fi
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$label"
  fi
}

has_hook() {
  [ -f "$1" ] && jq -e --arg c "$HOOK_CMD" \
    '[.hooks.SessionStart[]?.hooks[]? | select(.command == $c)] | length > 0' "$1" >/dev/null 2>&1
}

# ---- フック ----
add_hook() {
  local f="$1" tmp
  if has_hook "$f"; then
    info "フックは登録済みです: $f"
    return 0
  fi
  if [ -f "$f" ]; then
    run cp -p "$f" "$f.bak-$TS"
  else
    run mkdir -p "$(dirname "$f")"
  fi
  info "フックを足します: $f"
  [ "$dry_run" -eq 1 ] && return 0
  tmp="$(mktemp "$f.tmp.XXXXXX")"
  if [ -f "$f" ]; then
    jq --arg c "$HOOK_CMD" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"hooks": [{"type": "command", "command": $c}]}])' "$f" >"$tmp"
  else
    jq -n --arg c "$HOOK_CMD" '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": $c}]}]}}' >"$tmp"
  fi
  mv -f "$tmp" "$f"
}

remove_hook() {
  local f="$1" tmp
  has_hook "$f" || return 0
  run cp -p "$f" "$f.bak-$TS"
  info "フックを外します: $f"
  [ "$dry_run" -eq 1 ] && return 0
  tmp="$(mktemp "$f.tmp.XXXXXX")"
  # 足したフックだけを除き、空になった要素と配列を消す。他の設定は変えない。
  jq --arg c "$HOOK_CMD" '
    .hooks.SessionStart |= (map(.hooks |= map(select(.command != $c))) | map(select((.hooks | length) > 0)))
    | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end' "$f" >"$tmp"
  mv -f "$tmp" "$f"
}

# ---- スキル ----
link_skill() {
  local src="$1" dir="$2" name dest
  name="$(basename "$src")"
  dest="$dir/$name"
  # リンクに書かれた文字列が正しいパスと一致するときだけ作成済みとする。
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    info "リンクは作成済みです: $dest"
    return 0
  fi
  # 旧位置などを経由して同じ実体を指すリンクは、退避せずにその場で張り直す。
  if [ -L "$dest" ] && [ "$(real_path "$dest")" = "$src" ]; then
    local old
    old="$(readlink "$dest")"
    run ln -sfn "$src" "$dest"
    info "リンクを張り直しました: ${dest}（旧: ${old}）"
    return 0
  fi
  if [ -L "$dest" ] || [ -e "$dest" ]; then
    run mkdir -p "$dir/.trash"
    run mv "$dest" "$dir/.trash/$TS-$name"
    info "既存の $name を退避しました: $dir/.trash/$TS-$name"
  fi
  run ln -s "$src" "$dest"
}

# リンクがこのリポジトリを指すか。書かれた文字列か、実体をたどった先（旧位置を経由する場合）で判定する。
links_to_repo() {
  local e="$1"
  case "$(readlink "$e")" in "$REPO"/*) return 0 ;; esac
  case "$(real_path "$e")" in "$REPO"/*) return 0 ;; esac
  return 1
}

unlink_skills() {
  local dir="$1" e
  for e in "$dir"/* "$dir"/.[!.]*; do
    [ -L "$e" ] || continue
    if links_to_repo "$e"; then
      run rm "$e"
      info "リンクを消しました: $e"
    fi
  done
}

# ---- 通知の確認 ----
NOTIFY_TITLE="claude-review-inbox"
NOTIFY_MESSAGE="claude-review-inbox の通知の確認です"

# terminal-notifier で試しの通知を1回出す。失敗したらアプリとして1回起動してから、もう一度試す。
check_notifier() {
  local tn prefix app
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] （terminal-notifier があれば）試しの通知を出し、失敗したら open -W -a <terminal-notifier.app> で1回起動する\n'
    return 0
  fi
  tn="$(command -v terminal-notifier 2>/dev/null)" || return 0
  if "$tn" -title "$NOTIFY_TITLE" -message "$NOTIFY_MESSAGE" >/dev/null 2>&1; then
    info "試しの通知を出しました（terminal-notifier）"
    return 0
  fi
  warn "terminal-notifier で試しの通知を出せませんでした。アプリとして1回起動して、通知の許可を求めます"
  prefix=""
  if command -v brew >/dev/null 2>&1; then
    prefix="$(brew --prefix terminal-notifier 2>/dev/null || true)"
  fi
  app="$prefix/terminal-notifier.app"
  if [ -n "$prefix" ] && [ -d "$app" ]; then
    open -W -a "$app" --args -title "$NOTIFY_TITLE" -message "$NOTIFY_MESSAGE" || true
    if "$tn" -title "$NOTIFY_TITLE" -message "$NOTIFY_MESSAGE" >/dev/null 2>&1; then
      info "試しの通知を出しました（terminal-notifier をアプリとして起動した後）"
      return 0
    fi
  else
    warn "terminal-notifier.app の場所が分かりませんでした"
  fi
  warn "通知を出せませんでした。次の手順で許可してください（インストールは続けます）"
  info "  1. 「システム設定」の「通知」を開く"
  info "  2. 一覧の terminal-notifier を選び、「通知を許可」を有効にする"
  info "  3. 一覧に無い場合は、次を実行してから 1. に戻る"
  info "     open -W -a \"\$(brew --prefix terminal-notifier)/terminal-notifier.app\" --args -title test -message test"
}

# ---- launchd ----
write_plist() {
  local tmpl="$REPO/core/launchd/claude-review-inbox.plist.template" tmp
  run mkdir -p "$(dirname "$PLIST")"
  info "plist を書きます: $PLIST"
  [ "$dry_run" -eq 1 ] && return 0
  tmp="$(mktemp "$PLIST.tmp.XXXXXX")"
  sed -e "s|@@LABEL@@|$LABEL|g" -e "s|@@PYTHON@@|$PYTHON|g" \
    -e "s|@@SERVER@@|$REPO/core/server/inbox_server.py|g" \
    -e "s|@@PORT@@|$PORT|g" -e "s|@@STATE_DIR@@|$STATE_DIR|g" "$tmpl" >"$tmp"
  plutil -lint "$tmp" >/dev/null
  mv -f "$tmp" "$PLIST"
}

# ---- 定期実行（棚卸しと local の3つ） ----
# 台帳からジョブの行を出す。無ければ空。
job_entry() {
  [ -f "$JOBS_FILE" ] || return 0
  awk -F '\t' -v j="$1" '$1 == j { print; exit }' "$JOBS_FILE"
}

# 台帳のジョブの行を置き換える（引数がジョブ名だけなら消す）。中身が変わるときだけ書く。
set_job_entry() {
  local job="$1" tmp
  [ "$dry_run" -eq 1 ] && return 0
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "$JOBS_FILE.tmp.XXXXXX")"
  {
    if [ -f "$JOBS_FILE" ]; then awk -F '\t' -v j="$job" '$1 != j' "$JOBS_FILE"; fi
    if [ $# -gt 1 ]; then printf '%s\t%s\t%s\t%s\n' "$job" "$2" "$3" "$4"; fi
  } | LC_ALL=C sort >"$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$JOBS_FILE"
  elif [ -f "$JOBS_FILE" ] && cmp -s "$tmp" "$JOBS_FILE"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$JOBS_FILE"
  fi
}

# 台帳にあるジョブを launchd から外し、plist を消す。ラベルを引き継いだものは外す前に表示する。
unregister_job() {
  local job="$1" e label plist inherited
  e="$(job_entry "$job")"
  [ -n "$e" ] || return 0
  label="$(printf '%s' "$e" | cut -f2)"
  plist="$(printf '%s' "$e" | cut -f3)"
  inherited="$(printf '%s' "$e" | cut -f4)"
  if [ "$inherited" = "1" ]; then
    info "定期実行を外します（既存のラベルを引き継いだもの）: ${label}（${plist}）"
  else
    info "定期実行を外します: ${label}（${plist}）"
  fi
  bootout_if_registered "$label"
  if [ -e "$plist" ]; then run rm "$plist"; fi
  set_job_entry "$job"
}

# 既存の plist のうち、同じジョブの起動スクリプトを指すものを「ラベル<TAB>パス」で出す。
# スキル置き場の <ジョブ>/scripts/<スクリプト> と、リンクを解決した実体の両方で比べる。
find_existing_job_plist() {
  local job="$1" script="$2" want_real f arg d hit
  want_real="$REPO/local/skills/$job/scripts/$script"
  for f in "$AGENTS_DIR"/*.plist; do
    [ -f "$f" ] || continue
    arg="$(plutil -extract ProgramArguments.1 raw "$f" 2>/dev/null)" || continue
    hit=0
    [ "$(real_path "$arg")" = "$want_real" ] && hit=1
    for d in "${skill_dirs[@]}" "${config_dirs[@]/%//skills}"; do
      [ "$arg" = "$d/$job/scripts/$script" ] && hit=1
    done
    [ "$hit" -eq 1 ] || continue
    printf '%s\t%s\n' "$(plutil -extract Label raw "$f" 2>/dev/null)" "$f"
    return 0
  done
  return 1
}

# plist を置く。中身が同じなら書かない。backup が 1 なら、書き換える前に元を plist-backup へ複製する。
# 引数: <生成した一時ファイル> <置き場所> <backup>
place_plist() {
  local tmp="$1" dest="$2" backup="$3" bdir
  if ! plutil -lint "$tmp" >/dev/null; then
    rm -f "$tmp"
    warn "plist の形式が正しくありません: $dest"
    return 1
  fi
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    info "plist は作成済みです: $dest"
    return 0
  fi
  if [ "$backup" = "1" ] && [ -f "$dest" ]; then
    bdir="$STATE_DIR/plist-backup/$TS"
    mkdir -p "$bdir"
    cp -p "$dest" "$bdir/"
    info "既存の plist を複製しました: $bdir/$(basename "$dest")"
  fi
  mkdir -p "$(dirname "$dest")"
  mv -f "$tmp" "$dest"
  info "plist を書きました: $dest"
}

# ジョブを登録する。引数: <ジョブ名> <ラベル> <plist> <引き継いだなら1> <生成した一時ファイル（dry-run では空）>
register_job() {
  local job="$1" label="$2" plist="$3" inherited="$4" tmp="$5"
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] plist を書く: %s（ラベル %s）\n' "$plist" "$label"
    bootout_if_registered "$label"
    printf '[dry-run] launchctl bootstrap gui/%s %s\n' "$uid" "$plist"
    return 0
  fi
  place_plist "$tmp" "$plist" "$inherited" || return 1
  bootout_if_registered "$label"
  launchctl bootstrap "gui/$uid" "$plist"
  set_job_entry "$job" "$label" "$plist" "$inherited"
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 週1回の棚卸し（core の review-loop）を登録する。
register_review_loop() {
  local label="$LABEL_PREFIX.review-loop" plist tmp="" k v
  plist="$AGENTS_DIR/$label.plist"
  if ! is_uint "$LOOP_WEEKDAY" || ! is_uint "$LOOP_HOUR" || ! is_uint "$LOOP_MINUTE" \
    || [ "$LOOP_WEEKDAY" -gt 7 ] || [ "$LOOP_HOUR" -gt 23 ] || [ "$LOOP_MINUTE" -gt 59 ]; then
    warn "棚卸しの時刻の指定が正しくありません（曜日 ${LOOP_WEEKDAY}・時 ${LOOP_HOUR}・分 ${LOOP_MINUTE}）。登録しません"
    return 1
  fi
  info "週1回の棚卸しを登録します（曜日 ${LOOP_WEEKDAY}、$(printf '%02d:%02d' "$LOOP_HOUR" "$LOOP_MINUTE")）"
  if [ "$dry_run" -eq 0 ]; then
    mkdir -p "$STATE_DIR/review-loop" "$AGENTS_DIR"
    tmp="$(mktemp "$AGENTS_DIR/.$label.tmp.XXXXXX")"
    sed -e "s|@@LABEL@@|$label|g" -e "s|@@SCRIPT@@|${skill_dirs[0]}/review-loop/scripts/run.sh|g" \
      -e "s|@@WEEKDAY@@|$((10#$LOOP_WEEKDAY))|g" -e "s|@@HOUR@@|$((10#$LOOP_HOUR))|g" -e "s|@@MINUTE@@|$((10#$LOOP_MINUTE))|g" \
      -e "s|@@STATE_DIR@@|$STATE_DIR|g" "$REPO/core/launchd/review-loop.plist.template" >"$tmp"
    for k in MODEL EFFORT; do
      v="$(eval "printf '%s' \"\${CLAUDE_REVIEW_LOOP_$k:-}\"")"
      [ -z "$v" ] || plutil -insert "EnvironmentVariables.CLAUDE_REVIEW_LOOP_$k" -string "$v" "$tmp"
    done
  fi
  register_job review-loop "$label" "$plist" 0 "$tmp"
}

# local の定期実行を1つ登録する。既存の plist が同じスクリプトを別のラベルで指していれば、そのラベルを引き継ぐ。
register_local_job() {
  local job="$1" script="$2" tmpl label plist inherited=0 found tmp=""
  tmpl="$REPO/local/skills/$job/launchd/$job.plist.template"
  [ -f "$tmpl" ] || { warn "plist のひな形がありません: $tmpl"; return 1; }
  label="$LABEL_PREFIX.$job"
  plist="$AGENTS_DIR/$label.plist"
  if [ ! -f "$plist" ] && found="$(find_existing_job_plist "$job" "$script")"; then
    label="$(printf '%s' "$found" | cut -f1)"
    plist="$(printf '%s' "$found" | cut -f2)"
    inherited=1
    info "既存のラベルを引き継ぎます: ${label}（${plist}）"
  elif [ "$(job_entry "$job" | cut -f4)" = "1" ]; then
    inherited=1
    label="$(job_entry "$job" | cut -f2)"
    plist="$(job_entry "$job" | cut -f3)"
  fi
  if [ "$dry_run" -eq 0 ]; then
    mkdir -p "$AGENTS_DIR"
    tmp="$(mktemp "$AGENTS_DIR/.$job.tmp.XXXXXX")"
    sed -e "s|@@LABEL@@|$label|g" -e "s|@@SCRIPT@@|${skill_dirs[0]}/$job/scripts/$script|g" \
      -e "s|@@HOME@@|$HOME|g" "$tmpl" >"$tmp"
    mkdir -p "$(dirname "$(plutil -extract StandardOutPath raw "$tmp")")"
  fi
  register_job "$job" "$label" "$plist" "$inherited" "$tmp"
}

# ==== 外す ====
if [ "$uninstall" -eq 1 ]; then
  unregister_job review-loop
  for j in $LOCAL_JOBS; do unregister_job "${j%%:*}"; done
  bootout_if_registered
  if [ -e "$PLIST" ]; then
    run rm "$PLIST"
  fi
  for d in "${skill_dirs[@]}"; do
    [ -d "$d" ] && unlink_skills "$d"
  done
  if command -v jq >/dev/null 2>&1; then
    for f in "${settings_files[@]}"; do remove_hook "$f"; done
  else
    warn "jq が無いため、settings.json のフックを確かめられませんでした"
  fi
  for d in "${skill_dirs[@]}"; do
    for t in "$d"/.trash/*; do
      [ -e "$t" ] || [ -L "$t" ] || continue
      for s in "$REPO"/core/skills/* "$REPO"/local/skills/*; do
        case "$(basename "$t")" in
          *-"$(basename "$s")")
            info "退避したものがあります（自動では戻しません）: $t"
            info "  戻すには: mv '$t' '$d/$(basename "$s")'"
            ;;
        esac
      done
    done
  done
  info "外しました。案の置き場所（${PROPOSALS_DIR}）と台帳（${STATE_DIR}）は残しています。"
  exit 0
fi

# ==== 入れる ====
# 1. terminal-notifier
if command -v terminal-notifier >/dev/null 2>&1; then
  info "terminal-notifier は入っています"
elif command -v brew >/dev/null 2>&1; then
  run brew install terminal-notifier
else
  warn "terminal-notifier も brew もありません。通知は osascript で出します（押しても画面は開きません）"
fi
check_notifier

# 2. スキル
for d in "${skill_dirs[@]}"; do
  [ -d "$d" ] || run mkdir -p "$d"
  for s in "${skill_sources[@]}"; do link_skill "$s" "$d"; done
  # --with-local のときは、このリポジトリの review-loop を指す既存のリンクを外す（.trash へは移さない）。
  if [ "$with_local" -eq 1 ] && [ -L "$d/review-loop" ] && links_to_repo "$d/review-loop"; then
    run rm "$d/review-loop"
    info "リンクを消しました（--with-local では review-loop を入れない）: $d/review-loop"
  fi
done

# 5.（plist とログの置き場所に先に使う）案の置き場所と状態の置き場所
run mkdir -p "$PROPOSALS_DIR" "$STATE_DIR"

# 3. launchd
write_plist
bootout_if_registered
run launchctl bootstrap "gui/$uid" "$PLIST"

# 3.5 定期実行
if [ "$with_local" -eq 1 ]; then
  # local の3つが同じ役目を持つため、棚卸しは聞かずに登録しない（登録済みなら外す）。
  unregister_job review-loop
  for j in $LOCAL_JOBS; do
    register_local_job "${j%%:*}" "${j#*:}" || warn "定期実行 ${j%%:*} を登録できませんでした。インストールは続けます"
  done
else
  schedule=""
  case "$schedule_opt" in
    --with-schedule) schedule=1 ;;
    --no-schedule) schedule=0 ;;
    *)
      if [ -t 0 ]; then
        info "週1回の棚卸し（スキルとメモリの改善案づくり）は、あなたの Claude の利用枠を使います。"
        printf '週1回の棚卸しを入れますか [y/N] '
        ans=""
        read -r ans || ans=""
        case "$ans" in y|Y|yes|YES) schedule=1 ;; *) schedule=0 ;; esac
      else
        info "標準入力が端末ではないため、棚卸しの登録は変えません（登録するには --with-schedule を付けます）"
      fi
      ;;
  esac
  if [ "$schedule" = "1" ]; then
    register_review_loop || warn "棚卸しを登録できませんでした。インストールは続けます"
  elif [ "$schedule" = "0" ]; then
    unregister_job review-loop
  fi
fi

# 4. SessionStart フック
if command -v jq >/dev/null 2>&1; then
  for f in "${settings_files[@]}"; do
    if [ "$with_local" -eq 1 ]; then
      # local/skills/report-inbox のフックが件数を出すため、本体のフックは外す。
      remove_hook "$f"
    else
      add_hook "$f"
    fi
  done
else
  warn "jq が無いため、SessionStart フックを足していません。README の手順で手動で足してください"
fi

info ""
info "入れました。承認待ちの画面: http://127.0.0.1:$PORT/"
info "通知が出ない場合は、README の「5. 通知の許可」と「困ったとき」を参照してください。"
