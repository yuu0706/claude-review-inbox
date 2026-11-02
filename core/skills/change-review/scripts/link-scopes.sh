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

# ---- 南京錠: 定期実行の claude -p に書き換えさせない場所 ----

# 定期実行の共通の設定（jobs.conf）から値を読む。値の先頭の ~ だけを展開する。
lsc_jobs_conf() {
  local f="${CLAUDE_REVIEW_JOBS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-review-inbox/jobs.conf}" v
  [ -f "$f" ] || return 0
  v="$(sed -n "s/^$1=//p" "$f" | tail -n 1)"
  case "$v" in '~'*) v="$HOME${v#\~}" ;; esac
  printf '%s' "$v"
}

# 変更の台帳（Skill change-review の ledger.sh）の置き場所。環境変数 CLAUDE_CHANGE_LEDGER、jobs.conf、既定の順に決める。
change_ledger_dir() {
  local d="${CLAUDE_CHANGE_LEDGER:-}"
  [ -n "$d" ] || d="$(lsc_jobs_conf CLAUDE_CHANGE_LEDGER)"
  [ -n "$d" ] || d="$HOME/.local/state/claude-change-ledger"
  printf '%s\n' "${d%/}"
}

# 既定で書き換えを拒否するスクリプトの置き場所。フック（gitleaks-pre-commit.sh・tag-memory-repo.sh・SessionStart の
# unread.sh・run-if-due.sh・session-trigger.sh）と、それらが読み込む部品、定期実行の起動スクリプトを含む。
# 定期実行が自分の起動スクリプトを書き換えると、次の実行で拒否の規則そのものを外せるため、起動スクリプトも含める。
GUARDED_PATHS_DEFAULT="security-rules/scripts:memory-audit/scripts:report-inbox/scripts:repo-patrol/scripts:secret-patrol/scripts:skill-audit/scripts:feedback-mining/scripts:change-review/scripts:skill-updates/scripts:weakness-review/scripts"

# 書き換えを拒否する場所を「d<TAB>パス」（フォルダ）か「f<TAB>パス」（ファイル）で1行1件ずつ出力する。
# リンクの表記と実体のパスの両方を出す。
# 引数: <設定ディレクトリ>... -- <スキルの置き場所>...
# 対象:
#   - 安全のための規則のスキル全体（SKILL_AUDIT_PROTECTED。既定 security-rules commit-guard）
#   - フックと定期実行から呼ばれるスクリプト（CLAUDE_REVIEW_GUARDED_PATHS。コロン区切り。スキルの置き場所からの相対パスか絶対パス）
#   - 各設定ディレクトリの CLAUDE.md・settings.json・settings.local.json
#   - 変更の台帳（change_ledger_dir）
guard_paths() {
  local configs=() locs=() protected guarded c l n p q r k
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -- ]; then shift; break; fi
    configs+=("$1"); shift
  done
  locs=("$@")
  protected="${SKILL_AUDIT_PROTECTED:-}"
  [ -n "$protected" ] || protected="$(lsc_jobs_conf SKILL_AUDIT_PROTECTED)"
  [ -n "$protected" ] || protected="security-rules commit-guard"
  guarded="${CLAUDE_REVIEW_GUARDED_PATHS:-}"
  [ -n "$guarded" ] || guarded="$(lsc_jobs_conf CLAUDE_REVIEW_GUARDED_PATHS)"
  [ -n "$guarded" ] || guarded="$GUARDED_PATHS_DEFAULT"
  {
    for l in ${locs[@]+"${locs[@]}"}; do
      for n in $protected; do
        path_and_real "$l/$n" | sed 's/^/d	/'
      done
    done
    printf '%s\n' "$guarded" | tr ':' '\n' | while IFS= read -r p; do
      case "$p" in '~'*) p="$HOME${p#\~}" ;; esac
      p="${p%/}"
      [ -n "$p" ] || continue
      case "$p" in
        /*) printf '%s\n' "$p" ;;
        *) for l in ${locs[@]+"${locs[@]}"}; do printf '%s\n' "$l/$p"; done ;;
      esac
    done | while IFS= read -r q; do
      path_and_real "$q" | while IFS= read -r r; do
        k=f
        [ -d "$r" ] && k=d
        # 存在しないパスで末尾の要素に拡張子が無ければ、フォルダの形でも拒否して取りこぼさない。
        if [ ! -e "$r" ]; then
          case "${r##*/}" in *.*) ;; *) printf 'd\t%s\n' "$r" ;; esac
        fi
        printf '%s\t%s\n' "$k" "$r"
      done
    done
    for c in ${configs[@]+"${configs[@]}"}; do
      for n in CLAUDE.md settings.json settings.local.json; do
        path_and_real "$c/$n" | sed 's/^/f	/'
      done
    done
    path_and_real "${CLAUDE_REVIEW_CHANGES_LOG:-$HOME/.local/state/claude-reports/changes/log.md}" | sed 's/^/f	/'
    path_and_real "$(change_ledger_dir)" | sed 's/^/d	/'
  } | awk '!seen[$0]++'
  return 0
}

# guard_paths の結果を、--disallowedTools に渡す Edit の規則にして1行1件ずつ出力する。
# Edit の規則は Write など、ファイルを書き換える組み込みの道具すべてに効く。
guard_deny_rules() {
  local k p
  while IFS="	" read -r k p; do
    [ -n "$p" ] || continue
    if [ "$k" = d ]; then printf 'Edit(/%s/**)\n' "$p"; else printf 'Edit(/%s)\n' "$p"; fi
  done < <(guard_paths "$@")
  return 0
}
