#!/bin/bash
# requires: change-review feedback-mining memory-audit repo-patrol report-inbox secret-patrol skill-audit
# 南京錠（定期実行の claude -p に書き換えさせない場所）が、3つの定期実行の拒否の規則に入ることの検査。
# 安全のための規則のスキル・フックと定期実行のスクリプト・設定ファイル・変更の台帳を、リンクの表記と実体のパスの両方で拒否する。
# HOME を一時ディレクトリに差し替え、--dry-run で組み立てた引数（--disallowedTools の中身）だけを見る。本物の claude は起動しない。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$TESTS_DIR/../.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/guard-rules-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
unset CLAUDE_REPORTS_ROOT CLAUDE_REPORTS_STATE CLAUDE_REVIEW_PROPOSALS CLAUDE_REVIEW_STATE \
  SKILL_AUDIT_ROOT SKILL_AUDIT_STATE MEMORY_AUDIT_TARGETS FEEDBACK_MINING_SOURCES XDG_CONFIG_HOME \
  CLAUDE_LAUNCHER CLAUDE_REVIEW_DENY_READ CLAUDE_REVIEW_CONFIG_DIRS SKILL_AUDIT_EXCLUDE SKILL_AUDIT_OWN_LINK_ROOTS \
  CLAUDE_REVIEW_GUARDED_PATHS SKILL_AUDIT_PROTECTED CLAUDE_REVIEW_CHANGES_LOG
export CHANGE_REVIEW_SCRIPTS="$REPO/core/skills/change-review/scripts"
export CLAUDE_REVIEW_JOBS_CONF="$WORK/jobs.conf"
export CLAUDE_CHANGE_LEDGER="$WORK/change-ledger"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# 偽の HOME。security-rules は外部の実体へのリンク、commit-guard はふつうのフォルダ、
# このリポジトリのスキルはすべて実体へのリンクにする（install.sh が作る形）。
SK="$HOME/.claude/skills"
SEC_REAL="$WORK/ext/security-rules"
mkdir -p "$SK/commit-guard" "$SEC_REAL/scripts" "$HOME/.claude/projects/p1/memory" "$HOME/.local/bin"
printf '# sec\n' >"$SEC_REAL/SKILL.md"
printf '#!/bin/bash\n' >"$SEC_REAL/scripts/gitleaks-pre-commit.sh"
printf '# cg\n' >"$SK/commit-guard/SKILL.md"
ln -s "$SEC_REAL" "$SK/security-rules"
for s in "$REPO"/core/skills/*; do [ -d "$s" ] && ln -s "$s" "$SK/${s##*/}"; done
printf '# rules\n' >"$HOME/.claude/CLAUDE.md"
printf '{}\n' >"$HOME/.claude/settings.json"
printf 'm\n' >"$HOME/.claude/projects/p1/memory/a.md"
printf '{"type":"user","message":{"content":"x"}}\n' >"$HOME/.claude/projects/p1/s.jsonl"

# 3つの定期実行の --dry-run で、--disallowedTools より後（拒否の側）と前（許可の側）を取り出す。
run_job() {
  case "$1" in
    memory-audit) "$REPO/core/skills/memory-audit/scripts/run.sh" --dry-run 2>&1 ;;
    feedback-mining) "$REPO/core/skills/feedback-mining/scripts/run.sh" --dry-run 2>&1 ;;
    skill-audit) "$REPO/core/skills/skill-audit/scripts/run-audit.sh" --force --dry-run 2>&1 ;;
  esac
}
in_deny() { printf '%s' "${2#*--disallowedTools}" | grep -Fq -- "'$1'"; }
in_allow() { printf '%s' "${2%%--disallowedTools*}" | grep -Fq -- "'$1'"; }

for job in memory-audit feedback-mining skill-audit; do
  echo "== ${job}"
  out="$(run_job "$job")"; rc=$?
  check "${job}: 終了コード0" '[ "$rc" -eq 0 ]'
  check "${job}: --permission-mode default を付ける" 'printf "%s" "$out" | grep -Fq "'"'"'--permission-mode'"'"' '"'"'default'"'"'"'
  for rule in \
    "Edit(/$SK/security-rules/**)" "Edit(/$SEC_REAL/**)" "Edit(/$SK/commit-guard/**)" \
    "Edit(/$SEC_REAL/scripts/**)" "Edit(/$SK/security-rules/scripts/**)" \
    "Edit(/$SK/report-inbox/scripts/**)" "Edit(/$REPO/core/skills/report-inbox/scripts/**)" \
    "Edit(/$SK/memory-audit/scripts/**)" "Edit(/$REPO/core/skills/memory-audit/scripts/**)" \
    "Edit(/$REPO/core/skills/skill-audit/scripts/**)" "Edit(/$REPO/core/skills/change-review/scripts/**)" \
    "Edit(/$REPO/core/skills/feedback-mining/scripts/**)" "Edit(/$REPO/core/skills/repo-patrol/scripts/**)" \
    "Edit(/$REPO/core/skills/secret-patrol/scripts/**)" \
    "Edit(/$HOME/.claude/CLAUDE.md)" "Edit(/$HOME/.claude/settings.json)" "Edit(/$HOME/.claude/settings.local.json)" \
    "Edit(/$CLAUDE_CHANGE_LEDGER/**)" "Edit(/$HOME/.local/state/claude-reports/changes/log.md)"; do
    check "${job}: 拒否する: ${rule#Edit(/$WORK}" 'in_deny "$rule" "$out"'
  done
  for rule in "Edit(/$SEC_REAL/**)" "Edit(/$REPO/core/skills/report-inbox/scripts/**)"; do
    check "${job}: 許可の側に入れない: ${rule#Edit(/$WORK}" '! in_allow "$rule" "$out"'
  done
done

echo "== skill-audit: 元のスキルへの編集は許可しない"
out="$(run_job skill-audit)"
check "自作のスキル（report-inbox）の実体には Edit を許可しない" '! in_allow "Edit(/$REPO/core/skills/report-inbox/**)" "$out"'
check "その scripts は拒否する（拒否の規則が許可より優先する）" 'in_deny "Edit(/$REPO/core/skills/report-inbox/scripts/**)" "$out"'

echo "== 設定で拒否する場所を変えられる"
printf '#!/bin/bash\n' >"$WORK/hook-extra.sh"
printf 'CLAUDE_REVIEW_GUARDED_PATHS=%s:report-inbox/scripts/unread.sh\nSKILL_AUDIT_PROTECTED=commit-guard extra-skill\n' "$WORK/hook-extra.sh" >"$CLAUDE_REVIEW_JOBS_CONF"
for job in memory-audit feedback-mining skill-audit; do
  out="$(run_job "$job")"
  check "${job}: 絶対パスの指定をファイルとして拒否する" 'in_deny "Edit(/$WORK/hook-extra.sh)" "$out"'
  check "${job}: スキル置き場からの相対パスを表記と実体の両方で拒否する" 'in_deny "Edit(/$SK/report-inbox/scripts/unread.sh)" "$out" && in_deny "Edit(/$REPO/core/skills/report-inbox/scripts/unread.sh)" "$out"'
  check "${job}: 安全のための規則のスキルの一覧を設定で変える" 'in_deny "Edit(/$SK/extra-skill/**)" "$out"'
done
rm -f "$CLAUDE_REVIEW_JOBS_CONF"

echo "== 共通の処理（guard_paths）"
. "$CHANGE_REVIEW_SCRIPTS/link-scopes.sh"
g="$(guard_paths "$HOME/.claude" -- "$SK")"
check "重複が無い" '[ -z "$(printf "%s\n" "$g" | sort | uniq -d)" ]'
check "形は「d か f<TAB>パス」" '[ -z "$(printf "%s\n" "$g" | grep -v "^[df]	/")" ]'
check "台帳の既定は ~/.local/state/claude-change-ledger" '[ "$(env -u CLAUDE_CHANGE_LEDGER bash -c ". \"$CHANGE_REVIEW_SCRIPTS/link-scopes.sh\"; change_ledger_dir")" = "$HOME/.local/state/claude-change-ledger" ]'

echo "== 記録の差し替えとリンクの実体"
printf '# 記録\n' >"$WORK/actual-log.md"
ln -s "$WORK/actual-log.md" "$WORK/log.md"
export CLAUDE_REVIEW_CHANGES_LOG="$WORK/log.md"
for job in memory-audit feedback-mining skill-audit; do
  out="$(run_job "$job")"
  check "${job}: 記録をリンクと実体の両方で拒否する" 'in_deny "Edit(/$WORK/log.md)" "$out" && in_deny "Edit(/$WORK/actual-log.md)" "$out"'
done

printf '\nRESULT: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
