#!/bin/bash
# 直したいこと・未読の結果・定期実行の失敗を1行で知らせる。0件の項目は出さない。
# SessionStart ではどんな失敗でも終了コード0とする。
main() {
  local SCRIPT_DIR line day seq job path cur_job="" n=0 latest="" summary="" failures="" read_flag pending=0 oldest="" pid _rest where out=""
  local needs=0 count_sh="" c key num old nconfirm
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
  fi
  # 結果の置き場所が無くても、直したいことの記録を数える。
  for c in "${CHANGE_REVIEW_SCRIPTS:-}" "$SCRIPT_DIR/../../change-review/scripts" "$HOME/.claude/skills/change-review/scripts"; do
    if [ -n "$c" ] && [ -f "$c/count.sh" ]; then count_sh="$c/count.sh"; break; fi
  done
  if [ -n "$count_sh" ]; then
    while IFS="$TAB" read -r key num nconfirm old; do
      case "$num:$nconfirm" in *[!0-9:]*|:*) continue ;; esac
      [ "$key" = changes ] && pending="$num" && needs="$nconfirm" && oldest="$old"
    done < <(bash "$count_sh")
  else
    while IFS="$TAB" read -r pid head targets kind; do
      pending=$((pending + 1))
      [ -n "$oldest" ] || oldest="$pid"
      case "$kind" in 要確認*) needs=$((needs + 1)) ;; esac
    done < <(list_pending_changes)
  fi

  for job in $FAIL_JOBS; do
    check_job_failure "$job" || continue
    where=""
    [ -n "$FAIL_LOG" ] && where="ログ ${FAIL_LOG}"
    [ -n "$FAIL_STDERR" ] && where="${where}${where:+、}標準エラー ${FAIL_STDERR}"
    failures="${failures}${failures:+、}${job}（${FAIL_TIME}。${where}）"
  done

  [ "$pending" -gt 0 ] && out="直したいこと ${pending}件（うち要確認 ${needs}件、${oldest}〜）"
  [ -n "$summary" ] && out="${out}${out:+。}未読の結果: ${summary}"
  [ -n "$failures" ] && out="${out}${out:+。}失敗: ${failures}"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" || return 0
  fi
  return 0
}

main 2>/dev/null
exit 0
