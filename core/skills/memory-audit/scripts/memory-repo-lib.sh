#!/bin/bash
# tag-memory-repo.sh と backfill-memory-repo.sh が読み込む共通の関数。単体では実行しない。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。

# メモリのファイルの frontmatter の metadata の下へ、作成したリポジトリを表す2行を足す。
# 引数: <ファイル> <リポジトリ名> <リポジトリのパス> [--check]
# 戻り値: 0 = 足した（--check のときは足す対象である）、1 = 足す必要が無い（repo: が既にある、frontmatter が無い）、2 = 失敗
# 本文は head と tail で元のバイト列のまま写し、1バイトも変えない。書き込みは一時ファイルを mv で置き換える。
memory_add_repo() {
  local file="$1" repo="$2" repo_path="$3" mode="${4:-}"
  local close ins need_meta tmp perm
  [ -f "$file" ] || return 2
  [ -L "$file" ] && return 2
  # 1行目が --- で、2行目以降に閉じる --- がある場合だけ frontmatter とみなす。閉じる行の行番号を得る。
  close="$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { print NR; exit }' "$file")"
  [ -n "$close" ] || return 1
  if head -n "$close" "$file" | grep -Eq '^[[:space:]]*repo:'; then
    return 1
  fi
  # metadata の塊の最後の行を求める。塊は metadata: の行と、それに続く字下げされた行である。
  ins="$(head -n $((close - 1)) "$file" | awk '
    found == 0 && /^metadata:[[:space:]]*$/ { found = 1; last = NR; next }
    found == 1 { if ($0 ~ /^[[:space:]]/) { last = NR; next } found = 2 }
    END { if (found) print last }')"
  need_meta=0
  if [ -z "$ins" ]; then
    need_meta=1
    ins=$((close - 1))
  fi
  [ "$mode" = "--check" ] && return 0

  tmp="$(mktemp "${file%/*}/.memory-repo.XXXXXX")" || return 2
  {
    head -n "$ins" "$file"
    [ "$need_meta" -eq 1 ] && printf 'metadata:\n'
    printf '  repo: %s\n  repo_path: %s\n' "$repo" "$repo_path"
    tail -n +$((ins + 1)) "$file"
  } >"$tmp" || { rm -f "$tmp"; return 2; }
  perm="$(stat -f '%Lp' "$file" 2>/dev/null)" && chmod "$perm" "$tmp" 2>/dev/null
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 2; }
  return 0
}

# パスを Claude Code のプロジェクトのディレクトリ名と同じ形へ変換する（英数字以外を - にする）。
memory_encode_path() {
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g'
}

# 定期実行の共通の設定（jobs.conf）から、指定した名前の値を出力する。値の先頭の ~ だけを展開し、eval は使わない。
# 引数: <名前>
memory_jobs_conf() {
  local conf="${CLAUDE_REVIEW_JOBS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/jobs.conf}" v
  [ -f "$conf" ] || return 0
  v="$(sed -n "s/^$1=//p" "$conf" | tail -n 1)"
  case "$v" in '~'*) v="$HOME${v#\~}" ;; esac
  printf '%s' "$v"
}

# コロン区切りの一覧を1行1件で出力する。各要素の先頭の ~ を展開し、末尾の / を外す。
memory_split_dirs() {
  local IFS=: d
  for d in $1; do
    case "$d" in '~'*) d="$HOME${d#\~}" ;; esac
    [ -n "$d" ] && printf '%s\n' "${d%/}"
  done
}

# Claude の設定ディレクトリのうち存在するものを、1行1件で出力する。
# 一覧は環境変数 CLAUDE_REVIEW_CONFIG_DIRS、jobs.conf の同名の値、~/.claude の順で最初に得られたものを使う。
memory_config_dirs() {
  local dirs="${CLAUDE_REVIEW_CONFIG_DIRS:-}" d
  [ -n "$dirs" ] || dirs="$(memory_jobs_conf CLAUDE_REVIEW_CONFIG_DIRS)"
  [ -n "$dirs" ] || dirs="$HOME/.claude"
  memory_split_dirs "$dirs" | while IFS= read -r d; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# targets.conf の各行を展開し、存在するディレクトリの絶対パスを1行に1件ずつ出力する。
# 行頭の $CONFIG_DIR は設定ディレクトリの一覧の各要素に置き換え、$HOME と ${HOME} と ~ は展開する。
# eval は使わない。空行と # で始まる行は飛ばす。
# 引数: <targets.conf のパス>
memory_list_targets() {
  local conf="$1" pattern p real c
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in
      ''|'#'*) continue ;;
      '$CONFIG_DIR'*)
        while IFS= read -r c; do printf '%s\n' "$c${pattern#\$CONFIG_DIR}"; done < <(memory_config_dirs)
        continue ;;
    esac
    printf '%s\n' "$pattern"
  done <"$conf" | while IFS= read -r pattern; do
    case "$pattern" in
      '$HOME'*) pattern="$HOME${pattern#\$HOME}" ;;
      '${HOME}'*) pattern="$HOME${pattern#\$\{HOME\}}" ;;
      '~'*) pattern="$HOME${pattern#\~}" ;;
    esac
    for p in $pattern; do
      [ -d "$p" ] || continue
      [ -L "$p" ] && continue
      real="$(cd -P "$p" && pwd -P)" || continue
      printf '%s\n' "$real"
    done
  done | LC_ALL=C sort -u
}
