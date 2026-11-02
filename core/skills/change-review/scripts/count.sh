#!/bin/bash
# changes<TAB>未対応の件数<TAB>うち要確認の件数<TAB>最も古いID を出す。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
python3 -B "$SCRIPT_DIR/changes-log.py" count 2>/dev/null || printf 'changes\t0\t0\t\n'
exit 0
