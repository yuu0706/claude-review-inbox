#!/bin/bash
# 変更の台帳。定期実行が承認なしで反映した変更の、直す前と直した後の版を手元だけの git リポジトリに写してコミットする。
# スキルのリポジトリやメモリは git 管理されていないか、複数の会話が同時に直すため、そこへは自動でコミットしない。
# 使い方:
#   ledger.sh path
#       台帳の置き場所を出す（CLAUDE_CHANGE_LEDGER → jobs.conf の CLAUDE_CHANGE_LEDGER → ~/.local/state/claude-change-ledger）
#   ledger.sh record --id <ID> --kind <種類> --target <絶対パス> --before <直す前の版|-> [--after <直した後の版|->]
#       1件の変更を記録してコミットする。- は「無い」（追加なら直す前、削除なら直した後）。--after を省くと対象の今の状態を写す。
#       同じ ID で複数回呼ぶと、1つの変更に含まれるファイルとして続きの番号で記録する（メモリの削除と索引の行の削除など）。
#   ledger.sh revert <ID> [--force]
#       台帳から直す前の版を元の場所へ戻し、戻したことをコミットする。対象が直した後の版から変わっていれば、
#       --force が無い限り何も戻さずに終了コード 1 で止まる。
#   ledger.sh show <ID>
#       記録した対象と種類を出す。
#   ledger.sh since-seen [--mark|--print-head]
#       前回印を進めた後に記録した変更の ID を、古い順に1行1件で出す。--mark で印を今の位置へ進める。
#       --print-head は印を進めず、先頭に「head <コミット>」の1行を足す。
#   ledger.sh mark-seen <コミット>
#       印を指定したコミットへ進める。since-seen --print-head の結果を表示し終えてから呼ぶ。
# 台帳の中の形: entries/<ID>/<番号>/{target,kind,before,after}。before・after は「無い」ならファイルを置かない。
# bash 3.2（macOS 標準）で動くように書く。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/link-scopes.sh" || exit 1
LEDGER="$(change_ledger_dir)"

# 引数: <知らせる文> [<終了コード（既定 1）>]
die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

# 台帳だけで使う git。台帳は手元から出さないため、利用者の共通のフック（gitleaks の pre-commit 等）と署名は使わない。
# フックを通すと、メモリの本文が秘密の検査に当たったときに記録そのものが残らず、戻せなくなるためである。
lg() {
  git -C "$LEDGER" -c user.name=claude-change-ledger -c user.email=claude-change-ledger@localhost \
    -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"
}

ensure_repo() {
  [ -d "$LEDGER/.git" ] && return 0
  mkdir -p "$LEDGER" || return 1
  git -C "$LEDGER" init -q || return 1
  printf '# 変更の台帳\n\n定期実行が承認なしで反映した変更の、直す前と直した後の版の記録である（Skill change-review の ledger.sh が書く）。\n' >"$LEDGER/README.md"
  lg add README.md && lg commit -q -m "台帳を作る" >/dev/null
}

# ID として使ってよい文字だけかを確かめる（パスの部品になるため）。
valid_id() {
  case "$1" in ''|*/*|.*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  return 0
}

# パスの状態を写す。- か存在しなければ何も置かない。
copy_state() {
  local src="$1" dest="$2"
  [ "$src" = - ] && return 0
  [ -e "$src" ] || [ -L "$src" ] || return 0
  cp -RPp "$src" "$dest"
}

cmd_record() {
  local id="" kind="" target="" before="" after="__current__" n d
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id="${2-}"; shift 2 ;;
      --kind) kind="${2-}"; shift 2 ;;
      --target) target="${2-}"; shift 2 ;;
      --before) before="${2-}"; shift 2 ;;
      --after) after="${2-}"; shift 2 ;;
      *) die "不明な引数です: $1" 2 ;;
    esac
  done
  valid_id "$id" || die "ID が正しくありません: ${id}" 2
  [ -n "$kind" ] && [ -n "$before" ] || die "--kind と --before は必須です" 2
  case "$target" in /*) ;; *) die "--target は絶対パスで渡します: ${target}" 2 ;; esac
  [ "$after" = __current__ ] && after="$target"
  ensure_repo || die "台帳を作れません: ${LEDGER}"
  n=1
  while [ -e "$LEDGER/entries/$id/$n" ]; do n=$((n + 1)); done
  d="$LEDGER/entries/$id/$n"
  mkdir -p "$d" || die "台帳に書けません: ${d}"
  printf '%s\n' "$target" >"$d/target"
  printf '%s\n' "$kind" >"$d/kind"
  copy_state "$before" "$d/before" || die "直す前の版を写せません: ${before}"
  copy_state "$after" "$d/after" || die "直した後の版を写せません: ${after}"
  lg add -A "entries/$id" || die "台帳に追加できません"
  lg commit -q -m "record: ${id} ${kind} ${target}" >/dev/null || die "台帳にコミットできません"
  printf '%s\n' "$d"
}

# 記録の番号を、引数の順（昇順か降順）で出す。
entry_numbers() {
  local id="$1" order="$2" e
  for e in "$LEDGER/entries/$id"/*; do
    [ -f "$e/target" ] && printf '%s\n' "${e##*/}"
  done | if [ "$order" = desc ]; then sort -rn; else sort -n; fi
}

# 今の対象が、記録した直した後の版と同じなら 0 を返す。
same_as_after() {
  local d="$1" target
  target="$(cat "$d/target")"
  if [ ! -e "$d/after" ] && [ ! -L "$d/after" ]; then
    [ ! -e "$target" ] && [ ! -L "$target" ]
    return
  fi
  if [ -d "$d/after" ] && [ ! -L "$d/after" ]; then
    [ -d "$target" ] && diff -rq "$d/after" "$target" >/dev/null 2>&1
    return
  fi
  if [ -L "$d/after" ]; then
    [ -L "$target" ] && [ "$(readlink "$d/after")" = "$(readlink "$target")" ]
    return
  fi
  [ -f "$target" ] && cmp -s "$d/after" "$target"
}

cmd_show() {
  local id="$1" n d
  valid_id "$id" || die "ID が正しくありません: ${id}" 2
  [ -d "$LEDGER/entries/$id" ] || die "台帳にこの ID の記録がありません: ${id}（台帳 ${LEDGER}）"
  for n in $(entry_numbers "$id" asc); do
    d="$LEDGER/entries/$id/$n"
    printf '%s\t%s\n' "$(cat "$d/kind")" "$(cat "$d/target")"
  done
  [ -f "$LEDGER/entries/$id/reverted" ] && printf '戻し済み\t%s\n' "$(cat "$LEDGER/entries/$id/reverted")"
  return 0
}

cmd_revert() {
  local id="" force=0 n d target bad="" kind="" targets=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) id="$1"; shift ;;
    esac
  done
  valid_id "$id" || die "ID が正しくありません: ${id}" 2
  [ -d "$LEDGER/entries/$id" ] || die "台帳にこの ID の記録がありません: ${id}（台帳 ${LEDGER}）"
  [ -f "$LEDGER/entries/$id/reverted" ] && die "既に戻してあります: ${id}（$(cat "$LEDGER/entries/$id/reverted")）"
  for n in $(entry_numbers "$id" asc); do
    d="$LEDGER/entries/$id/$n"
    same_as_after "$d" || bad="${bad}  $(cat "$d/target")
"
  done
  if [ -n "$bad" ] && [ "$force" -ne 1 ]; then
    printf 'ERROR: 反映の後に次の対象が変わっているため、何も戻していません。今の内容を確かめ、上書きしてよければ --force を付けます。\n%s' "$bad" >&2
    exit 1
  fi
  for n in $(entry_numbers "$id" desc); do
    d="$LEDGER/entries/$id/$n"
    target="$(cat "$d/target")"
    kind="$(cat "$d/kind")"
    targets="${targets}${target}
"
    # 今の対象は消さずに台帳の removed へ移す（戻した後に、戻す前の状態も台帳に残すため）。
    if [ -e "$target" ] || [ -L "$target" ]; then
      rm -rf "$d/removed"
      mv "$target" "$d/removed" || die "今の対象を退避できません: ${target}"
    fi
    if [ -e "$d/before" ] || [ -L "$d/before" ]; then
      mkdir -p "${target%/*}" || die "元の場所のフォルダを作れません: ${target%/*}"
      cp -RPp "$d/before" "$target" || die "直す前の版を戻せません: ${target}"
    fi
  done
  date '+%Y-%m-%d %H:%M:%S' >"$LEDGER/entries/$id/reverted"
  lg add -A "entries/$id" || die "台帳に追加できません"
  lg commit -q -m "revert: ${id}" >/dev/null || die "台帳にコミットできません"
  printf '戻しました: %s（%s）\n' "$id" "$kind"
  printf '%s' "$targets" | sed 's/^/  /'
  printf '誤りだった場合は、訂正リストに「正しくは○○」を1行足します（Skill change-review の「8.」）:\n'
  printf '  bash %s/corrections.sh add --id %s --kind %s --target %s --correct "正しくは○○"\n' \
    "$SCRIPT_DIR" "$id" "$kind" "$(printf '%s' "$targets" | tail -n 1)"
}

cmd_since_seen() {
  local mark=0 print_head=0 seen head range
  case "${1-}" in
    --mark) mark=1 ;;
    --print-head) print_head=1 ;;
  esac
  [ -d "$LEDGER/.git" ] || return 0
  head="$(lg rev-parse -q --verify HEAD 2>/dev/null)" || return 0
  seen="$(cat "$LEDGER/.git/claude-seen" 2>/dev/null)"
  range="$head"
  if [ -n "$seen" ] && lg cat-file -e "${seen}^{commit}" 2>/dev/null; then
    range="${seen}..${head}"
  fi
  [ "$print_head" -eq 1 ] && printf 'head %s\n' "$head"
  lg log --reverse --format=%s "$range" 2>/dev/null | sed -n 's/^record: \([^ ]*\) .*/\1/p' | awk '!s[$0]++'
  [ "$mark" -eq 1 ] && printf '%s\n' "$head" >"$LEDGER/.git/claude-seen"
  return 0
}

# since-seen --print-head で受け取ったコミットまでを知らせ済みにする。since-seen の後に積まれたコミットは
# 次の会話で数えるため、今の HEAD ではなく受け取ったコミットを書く。
cmd_mark_seen() {
  local commit="${1-}"
  [ -d "$LEDGER/.git" ] || return 0
  lg cat-file -e "${commit}^{commit}" 2>/dev/null || return 2
  printf '%s\n' "$commit" >"$LEDGER/.git/claude-seen"
}

case "${1-}" in
  path) printf '%s\n' "$LEDGER" ;;
  record) shift; cmd_record "$@" ;;
  revert) shift; cmd_revert "$@" ;;
  show) shift; cmd_show "${1-}" ;;
  since-seen) shift; cmd_since_seen "$@" ;;
  mark-seen) shift; cmd_mark_seen "$@" ;;
  *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
