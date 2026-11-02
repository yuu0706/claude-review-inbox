#!/bin/bash
# changes.sh mark <ID> done|skip "<1行>"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
case "${1-}" in
  mark) exec python3 -B "$SCRIPT_DIR/changes-log.py" "$@" ;;
  *) printf '使い方: changes.sh mark <ID> done|skip "<1行>"\n' >&2; exit 2 ;;
esac
