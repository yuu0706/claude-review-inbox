#!/bin/bash
# 直したいことを記録の末尾に1件足し、ID を出す。採番と更新は .lock で排他する。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
exec python3 -B "$SCRIPT_DIR/changes-log.py" new "$@"
