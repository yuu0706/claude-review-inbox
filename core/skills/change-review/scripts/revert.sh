#!/bin/bash
# 承認なしで反映した変更を、変更の台帳から1コマンドで戻す。利用者が会話で「<ID> を戻して」と言ったときに使う。
# 使い方: revert.sh <ID> [--force]
#   台帳（ledger.sh path）から直す前の版を元の場所へ戻し、戻したことを台帳にコミットする。
#   反映の後に対象が変わっていれば、--force が無い限り何も戻さずに止まる。
#   戻した後に、訂正リストへ足すコマンドを表示する。
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [ "$#" -lt 1 ]; then
  sed -n '2,6p' "$0" >&2
  exit 2
fi
exec bash "$SCRIPT_DIR/ledger.sh" revert "$@"
