#!/bin/bash
# スキルのディレクトリを ROOT/.skill-audit-trash/ へ移動する。削除は行わない。
# 使い方: trash-skill.sh <対象スキル名>
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib.sh"

if [ $# -ne 1 ]; then
  log_error "usage: trash-skill.sh <skill-name>"
  exit 1
fi

skill="$1"

case "$skill" in
  *..*|*/*) log_error "名前に / または .. を含めることはできません: $skill"; exit 1 ;;
esac
if [ "$skill" = "$SELF_NAME" ]; then
  log_error "$SELF_NAME 自身は移動できません"
  exit 1
fi
if ! is_target "$skill"; then
  log_error "対象外のスキル名です: $skill"
  exit 1
fi
if [ -L "$ROOT/$skill" ]; then
  log_error "シンボリックリンクのスキルは移動できません: $skill"
  exit 1
fi

trash_root="$ROOT/.skill-audit-trash"
dest="$trash_root/$(date '+%Y-%m-%d-%H%M%S')-$skill"

if [ -e "$dest" ]; then
  log_error "移動先が既に存在します: $dest"
  exit 1
fi

mkdir -p "$trash_root" || exit 1
mv "$ROOT/$skill" "$dest" || exit 1
log_info "移動しました: $ROOT/$skill -> $dest"
