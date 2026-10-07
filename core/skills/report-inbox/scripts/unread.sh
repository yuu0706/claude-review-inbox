#!/bin/bash
# 未読のレポートをジョブごとに数え、1行だけ標準出力へ出す。未読も失敗も無ければ何も出さない。
# SessionStart フックで毎回動くため、どんな失敗でも終了コード0で何も出さない。
# 出力例: 未読の結果: feedback-mining 1件（2026-10-05）、repo-patrol 3件（最新 2026-10-07）
#         未読の結果: repo-patrol 1件（2026-10-07）。失敗: memory-audit（2026-10-05 10:30。ログ <パス>）
#         承認待ち 2件（2026-10-02-01〜）・承認済み・未反映 1件。未読の結果: repo-patrol 1件（2026-10-07）
# 定期実行の失敗の知らせも同じ行に載せる。失敗だけなら「失敗: …」だけを出す。
# Skill change-review の承認待ち（status が pending）と承認済み・未反映（status が approved）の件数を先頭に載せる。
# 0件の項目は出さない。承認待ちは既読にしない。件数は change-review の scripts/count.sh で数える。
# count.sh はスキル置き場の change-review を経由して探し、リポジトリの絶対パスを埋め込まない。見つからなければ
# lib.sh の list_pending_proposals で承認待ちだけを数える。

main() {
  local SCRIPT_DIR line day seq job path cur_job="" n=0 latest="" summary="" failures="" read_flag pending=0 oldest="" pid _rest where out=""
  local approved=0 count_sh="" c key num old
  SCRIPT_DIR="${0%/*}"
  [ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR="."
  . "$SCRIPT_DIR/lib.sh" || return 0
  check_read_file || return 0

  flush() {
    [ "$n" -gt 0 ] || return 0
    if [ "$n" -eq 1 ]; then
      summary="${summary}${summary:+、}${cur_job} 1件（${latest}）"
    else
      summary="${summary}${summary:+、}${cur_job} ${n}件（最新 ${latest}）"
    fi
  }

  # list_reports はジョブ名の順に出力するので、ジョブの切り替わりで集計を締める。
  # レポートの置き場所が無くても、失敗の知らせは調べる。
  if resolve_root; then
    while IFS="$TAB" read -r day seq job path read_flag; do
      if [ "$job" != "$cur_job" ]; then
        flush
        cur_job="$job"; n=0; latest=""
      fi
      [ "$read_flag" = "1" ] && continue
      n=$((n + 1))
      [[ "$day" > "$latest" ]] && latest="$day"
    done < <(list_reports_marked)
    flush
    for c in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" \
      "$HOME/.claude/skills/change-review/scripts"; do
      if [ -n "$c" ] && [ -f "$c/count.sh" ]; then
        count_sh="$c/count.sh"
        break
      fi
    done
    if [ -n "$count_sh" ]; then
      while IFS="$TAB" read -r key num old; do
        case "$num" in ''|*[!0-9]*) continue ;; esac
        case "$key" in
          pending) pending="$num"; oldest="$old" ;;
          approved) approved="$num" ;;
        esac
      done < <(CLAUDE_REVIEW_PROPOSALS="$PROPOSALS_DIR" bash "$count_sh")
    else
      # 承認待ちは id の昇順に出力されるので、先頭が最も古い。
      while IFS="$TAB" read -r pid _rest; do
        pending=$((pending + 1))
        [ -n "$oldest" ] || oldest="$pid"
      done < <(list_pending_proposals)
    fi
  fi

  for job in $FAIL_JOBS; do
    check_job_failure "$job" || continue
    where=""
    [ -n "$FAIL_LOG" ] && where="ログ ${FAIL_LOG}"
    [ -n "$FAIL_STDERR" ] && where="${where}${where:+、}標準エラー ${FAIL_STDERR}"
    failures="${failures}${failures:+、}${job}（${FAIL_TIME}。${where}）"
  done

  [ "$pending" -gt 0 ] && out="承認待ち ${pending}件（${oldest}〜）"
  [ "$approved" -gt 0 ] && out="${out}${out:+・}承認済み・未反映 ${approved}件"
  [ -n "$summary" ] && out="${out}${out:+。}未読の結果: ${summary}"
  [ -n "$failures" ] && out="${out}${out:+。}失敗: ${failures}"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

main 2>/dev/null
exit 0
