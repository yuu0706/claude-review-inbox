#!/bin/bash
# claude-review-inbox を入れる・外す。何回実行しても結果は同じになる。
# core/skills にあるスキルの分だけを扱う（公開版は1スキル＝1リポジトリで配るため。2026-11-05）。
# 使い方: ./install.sh [--with-schedule | --no-schedule] [--yes] [--dry-run] [--uninstall]
#   --with-schedule  週1回の見直し（memory-audit・feedback-mining・skill-audit・weakness-review のうち、あるもの）を聞かずに登録する
#   --no-schedule    週1回の見直しを登録しない（登録済みなら外す）
#   --yes            足りないもの（Xcode のコマンドラインツール）を聞かずに入れる。
#                    見回りの範囲は聞かずに「書類・デスクトップ・ダウンロードを入れない、リポジトリを見回らない」とする
#   --dry-run     何も変えず、必要なものの確認の結果・聞く内容・行う操作を表示する
#   --uninstall   launchd から外し、このリポジトリを指すリンクと足したフックを消す
# 環境変数:
#   CLAUDE_REVIEW_CHANGES_LOG  直したいことの記録（既定 ~/.local/state/claude-reports/changes/log.md）
#   CLAUDE_REVIEW_PYTHON  フックの設定に使う Python 3.9 以上（既定 /usr/bin/python3。Xcode のコマンドラインツールが必要）
#   XDG_CONFIG_HOME       見回りの範囲の設定ファイル（<XDG_CONFIG_HOME>/claude-review-inbox/patrol.conf）の置き場所（既定 ~/.config）
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
dry_run=0
uninstall=0
assume_yes=0
schedule_opt=""
for arg in "$@"; do
  case "$arg" in
    --with-local)
      printf 'ERROR: --with-local は不要になりました。付けずに実行してください\n' >&2
      exit 2
      ;;
    --dry-run) dry_run=1 ;;
    --uninstall) uninstall=1 ;;
    --with-schedule|--no-schedule)
      if [ -n "$schedule_opt" ] && [ "$schedule_opt" != "$arg" ]; then
        printf 'ERROR: --with-schedule と --no-schedule は同時に指定できません\n' >&2
        exit 2
      fi
      schedule_opt="$arg"
      ;;
    --yes) assume_yes=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) printf 'ERROR: 不明な引数です: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

user_name="$(id -un)"
uid="$(id -u)"
SYSTEM_PYTHON="${CLAUDE_REVIEW_SYSTEM_PYTHON:-/usr/bin/python3}"
PYTHON="${CLAUDE_REVIEW_PYTHON:-$SYSTEM_PYTHON}"
# 必要なものを探す場所。CLAUDE_REVIEW_XCODE_SELECT・_CLAUDE_PATHS・_SYSTEM_PYTHON は検査用。
XCODE_SELECT="${CLAUDE_REVIEW_XCODE_SELECT:-xcode-select}"
CLAUDE_PATHS="${CLAUDE_REVIEW_CLAUDE_PATHS-$HOME/.local/bin/claude $HOME/.claude/local/claude /opt/homebrew/bin/claude /usr/local/bin/claude}"
STATE_DIR="$HOME/.local/state/claude-review-inbox"
PROPOSALS_DIR="$HOME/claude-reports/proposals"
CHANGES_LOG="${CLAUDE_REVIEW_CHANGES_LOG:-$HOME/.local/state/claude-reports/changes/log.md}"
# このリポジトリにあるスキルか。公開版は組ごとに一部のスキルだけを持つ。
has_skill() { [ -d "$REPO/core/skills/$1" ]; }
# SessionStart フックに登録するコマンド。report-inbox の件数の1行、2つの見回りの起動、外部スキルの新しい版の確認である。
# このリポジトリにあるスキルの分だけを登録し、外す。
HOOK_CMDS=()
for c in report-inbox/scripts/unread.sh repo-patrol/scripts/run-if-due.sh \
  secret-patrol/scripts/session-trigger.sh skill-updates/scripts/run-if-due.sh; do
  has_skill "${c%%/*}" && HOOK_CMDS+=("$REPO/core/skills/$c")
done
# 旧版が登録したフック（スクリプトは削除済み）。report-inbox の unread.sh と同じ件数を出すため、見つけたら外す。
LEGACY_HOOK_CMD="$REPO/core/hooks/session-start.sh"
# 見回りの範囲の設定ファイル。repo-patrol と secret-patrol が読む。
PATROL_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/patrol.conf"
TS="$(date '+%Y%m%d-%H%M%S')"
AGENTS_DIR="$HOME/Library/LaunchAgents"
# install.sh が登録した定期実行の台帳。1行に「ジョブ名<TAB>ラベル<TAB>plist<TAB>引き継いだなら1」。
JOBS_FILE="$STATE_DIR/scheduled-jobs.tsv"
LABEL_PREFIX="com.${user_name//./-}"
# 週1回の見直しの定期実行: <ジョブ名>:<起動スクリプト>。repo-patrol と secret-patrol は SessionStart フックで動くため含めない。
# このリポジトリにあるジョブだけを登録し、外す（台帳は公開版の3つで共有するため、他の組のジョブには触れない）。
SCHEDULE_JOBS=""
schedule_names=""
for j in memory-audit:run.sh feedback-mining:run.sh skill-audit:run-audit.sh weakness-review:run.sh; do
  has_skill "${j%%:*}" || continue
  SCHEDULE_JOBS="${SCHEDULE_JOBS:+$SCHEDULE_JOBS }$j"
  schedule_names="${schedule_names:+${schedule_names}・}${j%%:*}"
done
SCHEDULE_QUESTION="週1回の見直し（${schedule_names}）を登録しますか。claude の利用枠を使います [y/N]"
# 見回りの範囲の設定は、repo-patrol か secret-patrol があるときだけ扱う。
has_patrol=0
{ has_skill repo-patrol || has_skill secret-patrol; } && has_patrol=1

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

# 設定ディレクトリの一覧。定期実行のスクリプトと同じく、環境変数 CLAUDE_REVIEW_CONFIG_DIRS、
# 共通の設定ファイル（jobs.conf）、既定の ~/.claude の順に決める（コロン区切り。先頭の ~ を展開する）。
# 2つ目の設定ディレクトリを使う場合は、jobs.conf に書く。存在しないものは使わない（~/.claude は常に含める）。
JOBS_CONF="${CLAUDE_REVIEW_JOBS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/jobs.conf}"
config_list="${CLAUDE_REVIEW_CONFIG_DIRS:-}"
if [ -z "$config_list" ] && [ -f "$JOBS_CONF" ]; then
  config_list="$(sed -n 's/^CLAUDE_REVIEW_CONFIG_DIRS=//p' "$JOBS_CONF" | tail -n 1)"
fi
config_dirs=("$HOME/.claude")
IFS=: read -r -a config_items <<<"$config_list"
for c in ${config_items[@]+"${config_items[@]}"}; do
  case "$c" in '~'*) c="$HOME${c#\~}" ;; esac
  c="${c%/}"
  [ -n "$c" ] && [ -d "$c" ] && [ "$c" != "$HOME/.claude" ] && config_dirs+=("$c")
done

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
for s in "$REPO"/core/skills/*/; do skill_sources+=("${s%/}"); done

# 登録済みなら launchd から外す。--dry-run では launchctl を一切呼ばず、行う操作だけを表示する。
# 引数: <ラベル>
bootout_if_registered() {
  local label="$1"
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] （登録済みなら）launchctl bootout gui/%s/%s\n' "$uid" "$label"
    return 0
  fi
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$label"
  fi
}

# settings.json の SessionStart フックを Python（標準ライブラリの json）で調べ・書き換える。
# 引数: <has|add|remove> <コマンド> <settings.json（add で新規なら空）> [<書き出し先>]
# 書かれたコマンドが同じ文字列か、~ と環境変数を展開してリンクを解決した先が同じファイルなら、同じフックとみなす。
# 既に手で登録したもの（スキル置き場を経由したパスなど）と二重に登録しないためである。
hook_json() {
  "$PYTHON" -B - "$1" "$2" "$3" "${4:-}" <<'PY'
import json, os, sys
mode, cmd, src, dest = sys.argv[1:5]
cmd_real = os.path.realpath(cmd)
def entries(d):
    h = d.get("hooks")
    s = h.get("SessionStart") if isinstance(h, dict) else None
    return s if isinstance(s, list) else []
def is_ours(x):
    if not isinstance(x, dict):
        return False
    c = x.get("command")
    if not isinstance(c, str):
        return False
    if c == cmd:
        return True
    p = os.path.expandvars(os.path.expanduser(c.strip()))
    return os.path.isabs(p) and os.path.realpath(p) == cmd_real
def inner(e):
    hs = e.get("hooks") if isinstance(e, dict) else None
    return hs if isinstance(hs, list) else []
if mode == "add" and not src:
    data = {}
else:
    try:
        with open(src, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        sys.exit(1)
    if not isinstance(data, dict):
        sys.exit(1)
if mode == "has":
    sys.exit(0 if any(is_ours(x) for e in entries(data) for x in inner(e)) else 1)
if mode == "add":
    if not isinstance(data.get("hooks"), dict):
        data["hooks"] = {}
    data["hooks"]["SessionStart"] = entries(data) + [{"hooks": [{"type": "command", "command": cmd}]}]
else:
    # 足したフックだけを除き、空になった要素と配列を消す。他の設定は変えない。
    kept = []
    for e in entries(data):
        if isinstance(e, dict) and isinstance(e.get("hooks"), list):
            e["hooks"] = [x for x in e["hooks"] if not is_ours(x)]
            if not e["hooks"]:
                continue
        kept.append(e)
    if kept:
        data["hooks"]["SessionStart"] = kept
    else:
        data["hooks"].pop("SessionStart", None)
        if not data["hooks"]:
            del data["hooks"]
with open(dest, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

# 引数: <settings.json> <コマンド>
has_hook() {
  [ -f "$1" ] && hook_json has "$2" "$1" 2>/dev/null
}

# ---- フック ----
# 書き換える前の settings.json を残す。1回の実行で複数のフックを書き換えても、最初の版だけを残す。
backup_settings() {
  [ -e "$1.bak-$TS" ] && return 0
  run cp -p "$1" "$1.bak-$TS"
}

# 引数: <settings.json> <コマンド>
add_hook() {
  local f="$1" cmd="$2" tmp
  if has_hook "$f" "$cmd"; then
    info "フックは登録済みです: ${f}（${cmd}）"
    return 0
  fi
  if [ -f "$f" ]; then
    backup_settings "$f"
  else
    run mkdir -p "$(dirname "$f")"
  fi
  info "フックを足します: ${f}（${cmd}）"
  [ "$dry_run" -eq 1 ] && return 0
  tmp="$(mktemp "$f.tmp.XXXXXX")"
  if [ -f "$f" ]; then
    if ! hook_json add "$cmd" "$f" "$tmp"; then
      rm -f "$tmp"
      warn "settings.json を JSON として読めないため、フックを足していません: $f"
      return 0
    fi
  else
    hook_json add "$cmd" "" "$tmp"
  fi
  mv -f "$tmp" "$f"
}

# 引数: <settings.json> <コマンド>
remove_hook() {
  local f="$1" cmd="$2" tmp
  has_hook "$f" "$cmd" || return 0
  backup_settings "$f"
  info "フックを外します: ${f}（${cmd}）"
  [ "$dry_run" -eq 1 ] && return 0
  tmp="$(mktemp "$f.tmp.XXXXXX")"
  hook_json remove "$cmd" "$f" "$tmp"
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

# 旧版の常駐サーバーを外す。同じ名前でも他のリポジトリを指す plist は残す。
remove_legacy_server() {
  local f arg label server_dir
  for f in "$AGENTS_DIR"/com.*.claude-review-inbox.plist; do
    [ -f "$f" ] || continue
    arg="$(plutil -extract ProgramArguments.1 raw "$f" 2>/dev/null)" || continue
    # 削除済みのスクリプトでも、親の core の実体から旧位置を経由するパスを判定する。
    server_dir="$(dirname "$arg")"
    [ "${server_dir##*/}" = server ] || continue
    [ "$(real_path "$(dirname "$server_dir")")" = "$REPO/core" ] || continue
    label="$(plutil -extract Label raw "$f" 2>/dev/null)" || continue
    [ -n "$label" ] || continue
    info "旧版のサーバーを外します: ${label}（${f}）"
    bootout_if_registered "$label"
    run rm "$f"
  done
}

# ---- 定期実行（週1回の見直しの3つ） ----
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
  want_real="$REPO/core/skills/$job/scripts/$script"
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

# 週1回の見直しの定期実行を1つ登録する。既存の plist が同じスクリプトを別のラベルで指していれば、そのラベルを引き継ぐ。
register_schedule_job() {
  local job="$1" script="$2" tmpl label plist inherited=0 found tmp=""
  tmpl="$REPO/core/skills/$job/launchd/$job.plist.template"
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

# ---- 見回りの範囲 ----
PATROL_Q_PERSONAL="書類・デスクトップ・ダウンロードのフォルダを、個人情報の置き忘れの見回りに入れますか。初めて見回るときに、macOS がフォルダへのアクセスの許可を求めます [y/N]"
PATROL_Q_REPOS="手元のリポジトリを置いているフォルダを入力してください（例: ~/Documents/git。空なら見回りません）"

# フォルダが書類・デスクトップ・ダウンロードの下にあれば 0 を返す。先頭の ~/ は HOME として扱う。
under_personal_folder() {
  local p="$1" d
  case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
  for d in Documents Desktop Downloads; do
    case "$p" in "$HOME/$d"|"$HOME/$d/"*) return 0 ;; esac
  done
  return 1
}

# repo-patrol と secret-patrol が読む設定ファイルを書く。既にあれば聞かずにその値を使う。
# --yes のときは聞かずに「入れない・見回らない」とする。macOS の許可を勝手に増やさないためである。
setup_patrol_conf() {
  local personal="no" roots="" ans="" r
  if [ -f "$PATROL_CONF" ]; then
    info "見回りの範囲は設定済みです（変えるときはこのファイルを直します）: $PATROL_CONF"
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] 聞く: %s\n' "$PATROL_Q_PERSONAL"
    printf '[dry-run] 聞く: %s\n' "$PATROL_Q_REPOS"
    printf '[dry-run] 答えを書く: %s\n' "$PATROL_CONF"
    return 0
  fi
  if [ "$assume_yes" -eq 1 ]; then
    info "--yes のため、見回りの範囲は聞かずに「書類・デスクトップ・ダウンロードを入れない、リポジトリを見回らない」とします"
  elif [ -t 0 ]; then
    printf '%s ' "$PATROL_Q_PERSONAL"
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) personal="yes" ;; esac
    printf '%s: ' "$PATROL_Q_REPOS"
    read -r roots || roots=""
    roots="$(printf '%s' "$roots" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "$roots" ]; then
      while IFS= read -r r; do
        if [ -n "$r" ] && under_personal_folder "$r"; then
          info "${r} は書類・デスクトップ・ダウンロードの下にあるため、初めて見回るときに macOS がフォルダへのアクセスの許可を求めます"
        fi
      done < <(printf '%s\n' "$roots" | tr ':' '\n')
    fi
  else
    info "標準入力が端末ではないため、見回りの範囲を聞かず、設定ファイルも書きません（書類・デスクトップ・ダウンロードとリポジトリは見回りません）"
    return 0
  fi
  mkdir -p "$(dirname "$PATROL_CONF")"
  {
    printf '# claude-review-inbox の見回りの範囲。install.sh が書いた。repo-patrol と secret-patrol が読む。\n'
    printf '# PERSONAL_FOLDERS: yes なら書類・デスクトップ・ダウンロードを個人情報の置き忘れの見回りに入れる\n'
    printf 'PERSONAL_FOLDERS=%s\n' "$personal"
    printf '# REPO_ROOTS: 手元のリポジトリを置いているフォルダ。複数はコロンで区切る。空なら見回らない\n'
    printf 'REPO_ROOTS=%s\n' "$roots"
  } >"$PATROL_CONF"
  info "見回りの範囲を書きました: $PATROL_CONF"
}

# ---- 必要なものの確認 ----
CLAUDE_BIN=""

# コマンドを PATH と、続けて渡した場所の順に探し、最初に見つかった実行できるパスを出す。
find_cmd() {
  local name="$1" p
  shift
  if p="$(command -v "$name" 2>/dev/null)" && [ -x "$p" ]; then
    printf '%s\n' "$p"
    return 0
  fi
  for p in "$@"; do
    if [ -f "$p" ] && [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# Xcode のコマンドラインツールがあるか。/usr/bin/python3 は実行しない（無い Mac では入れる画面が開くため）。
# Python は -B で動かす（HOME の Library/Caches にバイトコードを書かせない）。
has_clt() {
  local dev
  dev="$("$XCODE_SELECT" -p 2>/dev/null)" || return 1
  [ -n "$dev" ] && [ -x "$dev/usr/bin/python3" ]
}

# PYTHON を実行してよいか。既定の /usr/bin/python3 は、コマンドラインツールがあるときだけ実行する。
python_usable() {
  if [ "$PYTHON" = "$SYSTEM_PYTHON" ]; then
    has_clt
  else
    [ -x "$PYTHON" ]
  fi
}

# y/N で聞く。--yes なら聞かずに y、標準入力が端末でなければ聞かずに N とする。
ask() {
  local ans=""
  [ "$assume_yes" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

check_prerequisites() {
  local clt="" py_ok=0 py_state planned=() missing_required=0 st
  # 1. Xcode のコマンドラインツール（既定の /usr/bin/python3 を使うときだけ必要）
  if [ "$PYTHON" = "$SYSTEM_PYTHON" ]; then
    if has_clt; then clt="あり"; else clt="なし"; fi
  else
    clt="不要（CLAUDE_REVIEW_PYTHON を指定）"
  fi
  # 2. Python 3.9 以上
  if [ "$clt" = "なし" ]; then
    py_state="未確認（Xcode のコマンドラインツールが必要）"
  elif [ ! -x "$PYTHON" ]; then
    py_state="なし（${PYTHON}）"
  elif [ "$("$PYTHON" -B -c 'import sys; print(sys.version_info >= (3, 9))' 2>/dev/null)" = "True" ]; then
    py_ok=1
    py_state="あり（${PYTHON}）"
  else
    py_state="古い（${PYTHON}。3.9 以上が必要）"
  fi
  # 3. claude
  CLAUDE_BIN="$(find_cmd claude $CLAUDE_PATHS)" || CLAUDE_BIN=""

  info "必要なものの確認:"
  printf '  %s: %s\n' "Xcode のコマンドラインツール（必須）" "$clt"
  printf '  %s: %s\n' "Python 3.9 以上（必須）" "$py_state"
  st="なし"; [ -n "$CLAUDE_BIN" ] && st="あり（${CLAUDE_BIN}）"
  [ -n "$SCHEDULE_JOBS" ] && printf '  %s: %s\n' "claude（週1回の見直しに必要）" "$st"

  # 必須のもの
  if [ "$clt" = "なし" ]; then
    if [ "$dry_run" -eq 1 ]; then
      planned+=("Xcode のコマンドラインツール（xcode-select --install）")
      missing_required=1
    elif ask "Xcode のコマンドラインツールを入れますか。フックの設定に使う Python に必要です"; then
      "$XCODE_SELECT" --install || true
      info "画面の指示で入れ終えてから、もう一度 ./install.sh を実行してください"
      exit 2
    else
      info "Xcode のコマンドラインツールが無いため、フックを設定できません。入れずに終了します"
      info "入れ方: xcode-select --install を実行し、画面の指示で入れてから ./install.sh を実行してください"
      exit 2
    fi
  elif [ "$py_ok" -eq 0 ]; then
    info "Python 3.9 以上が見つからないため、フックを設定できません。入れずに終了します"
    info "別の Python を使う場合は、CLAUDE_REVIEW_PYTHON にそのパスを指定して ./install.sh を実行してください"
    if [ "$dry_run" -eq 0 ]; then exit 2; fi
    missing_required=1
  fi

  if [ -z "$CLAUDE_BIN" ] && [ -n "$SCHEDULE_JOBS" ]; then
    info "claude が見つからないため、週1回の見直しは登録しません（フックは使えます）"
  fi

  if [ "$dry_run" -eq 1 ]; then
    if [ "${#planned[@]}" -eq 0 ]; then
      info "[dry-run] 入れるものはありません"
    else
      info "[dry-run] 入れるもの（実際の実行では1つずつ確かめます）:"
      for st in "${planned[@]}"; do info "  - $st"; done
    fi
    if [ "$missing_required" -eq 1 ]; then
      info "[dry-run] 必須のものが足りないため、実際の実行はここで終了します"
      exit 2
    fi
  fi
}

# ==== 外す ====
if [ "$uninstall" -eq 1 ]; then
  # review-loop は旧版が登録した定期実行である。旧版から移ってきた環境のために外す（見直しの組の役目）。
  has_skill change-review && unregister_job review-loop
  for j in $SCHEDULE_JOBS; do unregister_job "${j%%:*}"; done
  remove_legacy_server
  # フックはリンクを消す前に外す。スキル置き場を経由して登録したフックを、リンクの先で同じものと判定するためである。
  if python_usable; then
    for f in "${settings_files[@]}"; do
      for c in ${HOOK_CMDS[@]+"${HOOK_CMDS[@]}"} "$LEGACY_HOOK_CMD"; do remove_hook "$f" "$c"; done
    done
  else
    warn "Python（${PYTHON}）を使えないため、settings.json のフックを確かめられませんでした"
  fi
  for d in "${skill_dirs[@]}"; do
    [ -d "$d" ] && unlink_skills "$d"
  done
  for d in "${skill_dirs[@]}"; do
    for t in "$d"/.trash/*; do
      [ -e "$t" ] || [ -L "$t" ] || continue
      for s in "$REPO"/core/skills/*; do
        case "$(basename "$t")" in
          *-"$(basename "$s")")
            info "退避したものがあります（自動では戻しません）: $t"
            info "  戻すには: mv '$t' '$d/$(basename "$s")'"
            ;;
        esac
      done
    done
  done
  kept="状態の置き場所（${STATE_DIR}）"
  has_skill change-review && kept="直したいことの記録（${CHANGES_LOG}）と否認・訂正リストの置き場所（${PROPOSALS_DIR}）と$kept"
  [ "$has_patrol" -eq 1 ] && kept="$kept と見回りの範囲の設定ファイル（${PATROL_CONF}）"
  info "外しました。${kept}は残しています。"
  exit 0
fi

# ==== 入れる ====
# 1. 必要なものの確認（足りないものは聞いてから入れる）
check_prerequisites

# 2. スキル
for d in "${skill_dirs[@]}"; do
  [ -d "$d" ] || run mkdir -p "$d"
  for s in "${skill_sources[@]}"; do link_skill "$s" "$d"; done
  # 旧版が置いた review-loop のリンク（このリポジトリを指すもの）を外す（.trash へは移さない）。
  if [ -L "$d/review-loop" ] && links_to_repo "$d/review-loop"; then
    run rm "$d/review-loop"
    info "旧版の review-loop のリンクを消しました: $d/review-loop"
  fi
done

# 記録と否認・訂正リストと状態の置き場所（記録と否認・訂正リストは見直しの組の分）
run mkdir -p "$STATE_DIR"
has_skill change-review && run mkdir -p "$(dirname "$CHANGES_LOG")" "$PROPOSALS_DIR"

# 旧版の常駐サーバーを外す。
remove_legacy_server

# 3.5 定期実行
# 旧版が登録した週1回の棚卸し（review-loop）は、週1回の見直しの3つに置き換わったため外す。
has_skill change-review && unregister_job review-loop
schedule=""
# claude が無いと見直しは動かないため、聞かずに登録しない（登録済みのものは変えない）。
# このリポジトリに週1回の見直しが無ければ、聞かずに何もしない。
if [ -z "$SCHEDULE_JOBS" ]; then
  schedule_opt="--skip"
elif [ -z "$CLAUDE_BIN" ] && [ "$schedule_opt" != "--no-schedule" ]; then
  schedule_opt="--skip"
fi
case "$schedule_opt" in
  --skip) ;;
  --with-schedule) schedule=1 ;;
  --no-schedule) schedule=0 ;;
  *)
    if [ "$dry_run" -eq 1 ]; then
      printf '[dry-run] 聞く: %s\n' "$SCHEDULE_QUESTION"
      info "[dry-run] y と答えた場合に行う操作:"
      schedule=1
    elif [ -t 0 ]; then
      printf '%s ' "$SCHEDULE_QUESTION"
      ans=""
      read -r ans || ans=""
      case "$ans" in y|Y|yes|YES) schedule=1 ;; *) schedule=0 ;; esac
    else
      info "標準入力が端末ではないため、週1回の見直しの登録は変えません（登録するには --with-schedule を付けます）"
    fi
    ;;
esac
if [ "$schedule" = "1" ]; then
  for j in $SCHEDULE_JOBS; do
    register_schedule_job "${j%%:*}" "${j#*:}" || warn "定期実行 ${j%%:*} を登録できませんでした。インストールは続けます"
  done
elif [ "$schedule" = "0" ]; then
  for j in $SCHEDULE_JOBS; do unregister_job "${j%%:*}"; done
fi

# 3.6 見回りの範囲（repo-patrol と secret-patrol）
[ "$has_patrol" -eq 1 ] && setup_patrol_conf

# 4. SessionStart フック
for f in "${settings_files[@]}"; do
  remove_hook "$f" "$LEGACY_HOOK_CMD"
  for c in ${HOOK_CMDS[@]+"${HOOK_CMDS[@]}"}; do add_hook "$f" "$c"; done
done

# change-review があるか（このリポジトリか、スキル置き場に）。終わりの案内と注意に使う（2026-11-05）。
cr_found=0
has_skill change-review && cr_found=1
for d in "${skill_dirs[@]}"; do
  [ -f "$d/change-review/scripts/link-scopes.sh" ] && cr_found=1
done

info ""
if has_skill report-inbox && [ "$cr_found" -eq 1 ]; then
  info "入れました。直したいことは会話の開始時に件数が出ます。"
elif has_skill report-inbox; then
  info "入れました。定期実行の結果と失敗は会話の開始時に知らせます。"
else
  info "入れました。会話の開始時の知らせが要るなら、claude-report-inbox も入れます。"
fi
# memory-audit・feedback-mining・skill-audit・weakness-review は、change-review の link-scopes.sh が無いと起動しない。
# 1スキルずつのリポジトリで入れたとき、change-review が入っていなければ知らせる（2026-11-05）。
needs_cr=""
for s in memory-audit feedback-mining skill-audit weakness-review; do
  has_skill "$s" && needs_cr="${needs_cr:+${needs_cr}・}$s"
done
if [ -n "$needs_cr" ] && [ "$cr_found" -eq 0 ]; then
  warn "${needs_cr} は change-review が無いと動きません。claude-change-review も入れてください（https://github.com/yuu0706/claude-change-review）"
fi
