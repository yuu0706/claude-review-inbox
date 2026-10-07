#!/bin/bash
# 既存のメモリへ、作成したリポジトリ（repo・repo_path）をあとから足す。
# 作成したリポジトリは、メモリのディレクトリの1つ上のディレクトリ名（作成時の cwd を変換したもの）から推定する。
# 使い方: backfill-memory-repo.sh [--apply]
#   既定では変更せず、足す内容を一覧で表示する。--apply のときだけ書き込む。
# 出力: 1行1件で「ファイル<TAB>repo<TAB>repo_path<TAB>判定の根拠」。最後に件数。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TARGETS_CONF="${MEMORY_AUDIT_TARGETS:-$SCRIPT_DIR/targets.conf}"
GIT_ROOT="${MEMORY_AUDIT_GIT_ROOT:-$HOME/Documents/git}"
. "$SCRIPT_DIR/memory-repo-lib.sh" || exit 1

log_error() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

apply=0
for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    *) log_error "不明な引数です: ${arg}"; exit 2 ;;
  esac
done

if [ ! -f "$TARGETS_CONF" ]; then
  log_error "設定ファイルがありません: ${TARGETS_CONF}"
  exit 1
fi

# 照合の候補。GIT_ROOT（既定 ~/Documents/git）の直下と、その1つ下のディレクトリである。並びは「変換後の名前<TAB>パス」。
candidates=()
for d in "$GIT_ROOT"/* "$GIT_ROOT"/*/*; do
  [ -d "$d" ] || continue
  candidates+=("$(memory_encode_path "$d")	$d")
done

# プロジェクトのディレクトリ名に最も長く前方一致する候補のパスを出力する。一致しなければ何も出さない。
match_dir() {
  local name="$1" c enc best="" best_len=0
  for c in ${candidates[@]+"${candidates[@]}"}; do
    enc="${c%%	*}"
    case "$name" in
      "$enc"|"$enc"-*) ;;
      *) continue ;;
    esac
    if [ "${#enc}" -gt "$best_len" ]; then
      best_len="${#enc}"
      best="${c#*	}"
    fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

total=0
added=0
skipped=0
failed=0
none=0
unknown=0
while IFS= read -r dir; do
  project="${dir%/*}"
  project="${project##*/}"
  if matched="$(match_dir "$project")"; then
    if top="$(git -C "$matched" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
      repo="${top##*/}"
      repo_path="$top"
    else
      repo="なし"
      repo_path="$matched"
    fi
    basis="$matched"
  else
    repo="なし"
    repo_path="不明"
    basis="一致なし（${project}）"
  fi

  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = "MEMORY.md" ] && continue
    total=$((total + 1))
    if [ "$apply" -eq 1 ]; then
      memory_add_repo "$f" "$repo" "$repo_path"
    else
      memory_add_repo "$f" "$repo" "$repo_path" --check
    fi
    case "$?" in
      0) ;;
      1) skipped=$((skipped + 1)); continue ;;
      *) failed=$((failed + 1)); log_error "書き込みに失敗しました: ${f}"; continue ;;
    esac
    added=$((added + 1))
    [ "$repo" = "なし" ] && none=$((none + 1))
    [ "$repo_path" = "不明" ] && unknown=$((unknown + 1))
    printf '%s\t%s\t%s\t%s\n' "$f" "$repo" "$repo_path" "$basis"
  done
done < <(memory_list_targets "$TARGETS_CONF")

if [ "$apply" -eq 1 ]; then
  verb="足した"
else
  verb="足す対象"
fi
printf '件数: 対象 %s件 / %s %s件（repo なし %s件、repo_path 不明 %s件） / repo: あり等で対象外 %s件 / 失敗 %s件\n' \
  "$total" "$verb" "$added" "$none" "$unknown" "$skipped" "$failed"
[ "$failed" -eq 0 ]
