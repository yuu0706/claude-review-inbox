#!/bin/bash
# 公開版のディレクトリに業務の語が混ざっていないかを、共通の検査器（check.sh）で調べる。run-audit.sh から週1回呼ばれる。
# 使い方: check-public.sh
#   公開版のディレクトリの一覧（1行1パス。「#」で始まる行と空行は使わない）を PUBLIC_DIRS_FILE から読む。一覧が無ければ何もしない。
#   当たり・検査の失敗・検査器が無い場合だけ、結果を REPORTS_ROOT/skill-audit/<YYYY-MM-DD>.md の「公開版の点検」の節に書く。
#   検出と報告だけを行い、公開版のファイルは直さない。
# 終了コード: 0 当たり無し・一覧が無い / 1 当たり・検査の失敗・検査器が無い（結果を書いた）
set -u

PUBLIC_DIRS_FILE="${SKILL_AUDIT_PUBLIC_DIRS:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-skills/public-dirs.txt}"
CHECK_DIR_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-skills/public-check-dir"
CHECKER_DIR="${PUBLIC_CHECK_DIR:-}"
if [ -z "$CHECKER_DIR" ] && [ -f "$CHECK_DIR_FILE" ]; then
  IFS= read -r CHECKER_DIR <"$CHECK_DIR_FILE" || true
  case "$CHECKER_DIR" in '~'*) CHECKER_DIR="$HOME${CHECKER_DIR#\~}" ;; esac
fi
CHECKER_DIR="${CHECKER_DIR%/}"
REPORT_DIR="${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}"
REPORT_DIR="${REPORT_DIR%/}/skill-audit"

[ -f "$PUBLIC_DIRS_FILE" ] || exit 0
dirs=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in '~'*) line="$HOME${line#\~}" ;; esac
  dirs+=("${line%/}")
done <"$PUBLIC_DIRS_FILE"
[ "${#dirs[@]}" -gt 0 ] || exit 0

body=""
found=0
if [ -z "$CHECKER_DIR" ]; then
  found=1
  body="- 検査器の場所が設定されていないため、点検をしていない（環境変数 PUBLIC_CHECK_DIR か \`$CHECK_DIR_FILE\` に検査器のディレクトリを書く）"$'\n'
elif [ ! -x "$CHECKER_DIR/check.sh" ]; then
  found=1
  body="- 共通の検査器が見つからないため、点検をしていない: \`$CHECKER_DIR/check.sh\`（環境変数 PUBLIC_CHECK_DIR で場所を変えられる）"$'\n'
else
  for d in "${dirs[@]}"; do
    if [ ! -d "$d" ]; then
      found=1
      body="$body- \`$d\`: ディレクトリが存在しない"$'\n'
      continue
    fi
    out="$("$CHECKER_DIR/check.sh" "$d" 2>&1)"
    rc=$?
    case "$rc" in
      0) ;;
      1)
        found=1
        body="$body- \`$d\`: 業務の語が当たった（$(printf '%s\n' "$out" | grep -c .)行）"$'\n\n```\n'"$out"$'\n```\n'
        ;;
      *)
        found=1
        body="$body- \`$d\`: 検査器が失敗した（終了コード ${rc}）"$'\n\n```\n'"$out"$'\n```\n'
        ;;
    esac
  done
fi

if [ "$found" -eq 0 ]; then
  printf '公開版の点検: 当たりはありませんでした（%s件）\n' "${#dirs[@]}"
  exit 0
fi

# 同じ日に2回目以降は -2、-3 と連番にし、前の結果を上書きしない（Skill report-inbox のファイル名の形）。
mkdir -p "$REPORT_DIR" || exit 1
day="$(date '+%Y-%m-%d')"
report="$REPORT_DIR/$day.md"
n=2
while [ -e "$report" ]; do report="$REPORT_DIR/$day-$n.md"; n=$((n + 1)); done
{
  printf '# skill-audit の結果（%s）\n\n' "$day"
  printf '## 公開版の点検\n\n'
  printf '一覧 `%s` の公開版を、共通の検査器 `%s/check.sh` で調べた。公開版のファイルは直していない。\n\n' "$PUBLIC_DIRS_FILE" "$CHECKER_DIR"
  printf '%s' "$body"
} >"$report"
printf '公開版の点検: 結果を書きました: %s\n' "$report"
exit 1
