#!/bin/bash
# スキルの置き場所の直下にあるシンボリックリンクの実体を求める共通の処理。各スクリプトから source して使う。
# claude -p の権限は、シンボリックリンクをたどった先の実体のパスで判定される。リンクの表記だけを許可しても
# 実体を読めないため、許可と拒否の規則を実体のパスでも書く必要がある。
# bash 3.2（macOS 標準）で動くように書く。連想配列と mapfile は使わない。

# パスの実体の絶対パスを出力する。存在しない・解決できない場合は何も出さず 1 を返す。
real_path_of() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd -P "$p" 2>/dev/null && pwd -P)
    return
  fi
  [ -e "$p" ] || return 1
  readlink -f "$p" 2>/dev/null
}

# 引数のパスを出力し、実体のパスが異なればそれも出力する。拒否の規則を両方の表記で書くために使う。
path_and_real() {
  local r
  printf '%s\n' "$1"
  r="$(real_path_of "$1")" || return 0
  [ -n "$r" ] && [ "$r" != "$1" ] && printf '%s\n' "$r"
  return 0
}

# スキルの置き場所の一覧を出力する。引数が無ければ ~/.claude/skills。
# 2つ目の設定ディレクトリを使う場合は、呼び出し側がその skills も引数で渡す。
skill_locations() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
  else
    printf '%s\n' "$HOME/.claude/skills"
  fi
  return 0
}

# スキルの置き場所（引数。省略時は skill_locations の既定）の直下にあるシンボリックリンクについて、
# リンクの先の実体のディレクトリを重複なく1行に1件ずつ出力する。置き場所そのものがリンクなら、その実体も出力する。
# 実体が無いリンク・ディレクトリでないリンクは飛ばす。
skill_link_reals() {
  local loc real e r seen dirs
  seen="
"
  dirs=""
  while IFS= read -r loc; do
    [ -n "$loc" ] || continue
    [ -d "$loc" ] || continue
    if [ -L "$loc" ]; then
      real="$(real_path_of "$loc")" || continue
      case "$seen" in *"
$real
"*) ;; *) seen="$seen$real
"; printf '%s\n' "$real" ;; esac
    fi
    for e in "$loc"/* "$loc"/.[!.]*; do
      [ -L "$e" ] || continue
      [ -d "$e" ] || continue
      r="$(real_path_of "$e")" || continue
      [ -n "$r" ] || continue
      case "$seen" in *"
$r
"*) continue ;; esac
      seen="$seen$r
"
      printf '%s\n' "$r"
    done
  done < <(skill_locations "$@")
  return 0
}
