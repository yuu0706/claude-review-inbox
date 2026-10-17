#!/bin/bash
# 外部スキルを更新した後に、記録を「直近の確認で見た上流のコミット」へ進める。ネットワークは使わない。
# 使い方: mark-updated.sh <スキル名>
# 進めなくても、次の日の確認で上流と手元の中身が一致すれば記録は自動で進む。
# このスクリプトは、同じ日のうちに知らせを止めたいときと、中身が一致しない形で入れたとき（手で直したなど）に使う。
set -euo pipefail

[ $# -eq 1 ] && [ -n "$1" ] || { printf '使い方: %s <スキル名>\n' "$0" >&2; exit 2; }
PYTHON="${CLAUDE_REVIEW_PYTHON:-/usr/bin/python3}"
STATE_BASE="${CLAUDE_REPORTS_STATE:-$HOME/.local/state/claude-reports}"
STATE_FILE="${SKILL_UPDATES_STATE:-${STATE_BASE%/}/skill-updates}/state.json"

"$PYTHON" -B -I - "$STATE_FILE" "$1" <<'PY'
import json, os, sys
path, name = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as f:
        state = json.load(f)
except (OSError, ValueError):
    state = {}
rec = state.get(name) if isinstance(state, dict) else None
if not isinstance(rec, dict) or not rec.get("latest_seen"):
    print("ERROR: %s の確認の記録がありません: %s" % (name, path), file=sys.stderr)
    sys.exit(1)
rec["installed"] = rec["latest_seen"]
rec.pop("summary", None)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("記録を進めました: %s（%s）" % (name, rec["installed"]))
PY
