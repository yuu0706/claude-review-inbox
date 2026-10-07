#!/bin/bash
# skill-audit 共通定義。各スクリプトから source して使う。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。

# 定期実行の共通の設定（jobs.conf）。環境変数が設定ファイルより優先する。値の先頭の ~ だけを展開し、eval は使わない。
JOBS_CONF="${CLAUDE_REVIEW_JOBS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/jobs.conf}"
jobs_conf() {
  local v
  [ -f "$JOBS_CONF" ] || return 0
  v="$(sed -n "s/^$1=//p" "$JOBS_CONF" | tail -n 1)"
  case "$v" in '~'*) v="$HOME${v#\~}" ;; esac
  printf '%s' "$v"
}
# コロン区切りの一覧を1行に1件ずつ出力する。先頭の ~ を展開する。
split_dirs() {
  local IFS=: d
  for d in $1; do
    case "$d" in '~'*) d="$HOME${d#\~}" ;; esac
    [ -n "$d" ] && printf '%s\n' "${d%/}"
  done
}

[ -n "${SKILL_AUDIT_ROOT:-}" ] || SKILL_AUDIT_ROOT="$(jobs_conf SKILL_AUDIT_ROOT)"
ROOT="${SKILL_AUDIT_ROOT:-$HOME/.claude/skills}"
ROOT="${ROOT%/}"
STATE_DIR="${SKILL_AUDIT_STATE:-$HOME/.local/state/skill-audit}"
STATE_DIR="${STATE_DIR%/}"
SELF_NAME="skill-audit"
# 変更の記録と直す前の複製。スキル置き場の外に置き、精査の対象と比較に入れない。
HISTORY_FILE="$STATE_DIR/history.md"
HISTORY_DIR="$STATE_DIR/history"

# 精査の対象から外すエントリ名（空白区切り）。同期やプラグインの置き場所、外部から導入したスキルを指定する。
# ドット始まりは名前によらず別途除外する。
[ -n "${SKILL_AUDIT_EXCLUDE:-}" ] || SKILL_AUDIT_EXCLUDE="$(jobs_conf SKILL_AUDIT_EXCLUDE)"
read -r -a EXCLUDE_NAMES <<<"${SKILL_AUDIT_EXCLUDE:-}"

# シンボリックリンクのスキルのうち、実体がこの下にあるものを自作のスキルとして精査の対象にする。コロン区切り。
# 既定は本リポジトリの core/skills である（skill-audit・memory-audit 等の実体）。外部から導入したスキルと
# 別リポジトリのスキルの実体は含めない。
[ -n "${SKILL_AUDIT_OWN_LINK_ROOTS:-}" ] || SKILL_AUDIT_OWN_LINK_ROOTS="$(jobs_conf SKILL_AUDIT_OWN_LINK_ROOTS)"
OWN_LINK_ROOTS="${SKILL_AUDIT_OWN_LINK_ROOTS:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)}"

# ROOT 直下のシンボリックリンクが自作のスキル（実体が OWN_LINK_ROOTS の下にあるディレクトリ）なら 0 を返す。
is_own_link() {
  local name="$1" real r rest
  [ -L "$ROOT/$name" ] && [ -d "$ROOT/$name" ] || return 1
  real="$(cd -P "$ROOT/$name" 2>/dev/null && pwd -P)" || return 1
  rest="$OWN_LINK_ROOTS"
  while [ -n "$rest" ]; do
    r="${rest%%:*}"
    [ "$r" = "$rest" ] && rest="" || rest="${rest#*:}"
    r="${r%/}"
    [ -n "$r" ] || continue
    r="$(cd -P "$r" 2>/dev/null && pwd -P)" || continue
    case "$real" in "$r"/*) return 0 ;; esac
  done
  return 1
}

is_excluded_name() {
  local name="$1" e
  for e in ${EXCLUDE_NAMES[@]+"${EXCLUDE_NAMES[@]}"}; do
    [ "$name" = "$e" ] && return 0
  done
  return 1
}

# 名前が対象であれば 0 を返す。
is_target() {
  local name="$1"
  [ -n "$name" ] || return 1
  case "$name" in
    .*|*/*) return 1 ;;
  esac
  is_excluded_name "$name" && return 1
  if [ -L "$ROOT/$name" ]; then
    is_own_link "$name" || return 1
  fi
  [ -d "$ROOT/$name" ] || return 1
  return 0
}

# 対象のスキル名を1行に1件ずつ出力する。
list_targets() {
  local path name
  for path in "$ROOT"/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name="${path##*/}"
    is_target "$name" && printf '%s\n' "$name"
  done
  return 0
}

# ルート直下のシンボリックリンク名を1行に1件ずつ出力する。
list_symlinks() {
  local path
  for path in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -L "$path" ] && printf '%s\n' "${path##*/}"
  done
  return 0
}

# ルート直下のドット始まりのエントリ名を出力する（シンボリックリンクを除く）。
list_dot_entries() {
  local path
  for path in "$ROOT"/.[!.]*; do
    [ -e "$path" ] && [ ! -L "$path" ] && printf '%s\n' "${path##*/}"
  done
  return 0
}

# シンボリックリンクの実体の絶対パスを出力する。解決できなければ 1 を返す。
resolve_link() {
  local link="$1"
  if [ -d "$link" ]; then
    (cd -P "$link" 2>/dev/null && pwd -P)
  else
    readlink -f "$link" 2>/dev/null
  fi
}

# 起動するコマンド。空白で区切った語の {job} はジョブ名に置き換える（例: 別アカウントで起動するラッパー {job}）。
[ -n "${CLAUDE_LAUNCHER:-}" ] || CLAUDE_LAUNCHER="$(jobs_conf CLAUDE_LAUNCHER)"
[ -n "$CLAUDE_LAUNCHER" ] || CLAUDE_LAUNCHER=claude
# Claude の設定ディレクトリの一覧（コロン区切り）。2つ目の設定ディレクトリを使う場合はここに足す。存在するものだけを使う。
[ -n "${CLAUDE_REVIEW_CONFIG_DIRS:-}" ] || CLAUDE_REVIEW_CONFIG_DIRS="$(jobs_conf CLAUDE_REVIEW_CONFIG_DIRS)"
[ -n "$CLAUDE_REVIEW_CONFIG_DIRS" ] || CLAUDE_REVIEW_CONFIG_DIRS="$HOME/.claude"
# 読み取りを拒否する追加の場所（コロン区切り）。クラウドストレージの同期フォルダ等を指定する。
[ -n "${CLAUDE_REVIEW_DENY_READ:-}" ] || CLAUDE_REVIEW_DENY_READ="$(jobs_conf CLAUDE_REVIEW_DENY_READ)"
CONFIG_DIRS=()
while IFS= read -r d; do [ -d "$d" ] && CONFIG_DIRS+=("$d"); done < <(split_dirs "$CLAUDE_REVIEW_CONFIG_DIRS")
DENY_READ_EXTRA=()
while IFS= read -r d; do DENY_READ_EXTRA+=("$d"); done < <(split_dirs "${CLAUDE_REVIEW_DENY_READ:-}")
SKILL_DIRS=()
for c in ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do SKILL_DIRS+=("$c/skills"); done

log_error() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_info() {
  printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
