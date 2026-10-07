#!/bin/bash
# 修正前のファイルを STATE_DIR/history/<日付>/ へ退避する。
# 使い方: snapshot.sh <対象スキル名> <スキル内の相対パス>
# 同じ日に同じファイルの退避が既にあれば上書きしない（その日の最初の版を残す）。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib.sh"

if [ $# -ne 2 ]; then
  log_error "usage: snapshot.sh <skill-name> <relative-path>"
  exit 1
fi

skill="$1"
rel="$2"

if ! is_target "$skill"; then
  log_error "対象外のスキル名です: $skill"
  exit 1
fi

case "$rel" in
  ''|/*) log_error "相対パスを指定してください: $rel"; exit 1 ;;
esac
case "/$rel/" in
  */../*|*/./*) log_error "パスに . または .. を含めることはできません: $rel"; exit 1 ;;
esac

# 途中の各要素がシンボリックリンクでないことを確かめる。
cur="$ROOT/$skill"
rest="$rel"
while [ -n "$rest" ]; do
  part="${rest%%/*}"
  if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
  [ -n "$part" ] || continue
  cur="$cur/$part"
  if [ -L "$cur" ]; then
    log_error "シンボリックリンクを含むパスは扱いません: $rel"
    exit 1
  fi
done

if [ ! -f "$cur" ]; then
  log_error "ファイルが存在しません: $skill/$rel"
  exit 1
fi

day="$(date '+%Y-%m-%d')"
dest_dir="$HISTORY_DIR/$day"
dest="$dest_dir/${skill}__${rel//\//_}.bak"

if [ -e "$dest" ]; then
  log_info "本日の退避が既にあるため上書きしません: $dest"
  exit 0
fi

mkdir -p "$dest_dir" || exit 1
cp -p "$cur" "$dest" || exit 1
log_info "退避しました: $dest"
