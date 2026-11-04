# requires: change-review
"""直したいことの追記・区分・件数・状態変更を検査する。"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CR = Path(__file__).resolve().parents[1] / 'skills/change-review/scripts'

class ChangesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.log = self.root / 'state/changes/log.md'
        self.env = dict(os.environ, HOME=str(self.root), CLAUDE_REVIEW_CHANGES_LOG=str(self.log), CLAUDE_REVIEW_PROPOSALS=str(self.root / 'proposals'))
        self.diff = self.root / 'diff'
        self.diff.write_text('--- /abs/x.md\n+++ /abs/x.md\n@@ -1 +1 @@\n-old\n+new\n', encoding='utf-8')
        self.target = '/abs/x.md'

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(CR / name), *args], env=self.env, capture_output=True, text=True)

    def new(self, *args):
        r = self.run_script('new-change.sh', '--source', '会話', '--title', '直す', '--diff-file', str(self.diff), '--target', self.target, *args)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def propose(self, *args):
        dest = self.root / 'dest'
        dest.mkdir(exist_ok=True)
        r = self.run_script('propose.sh', '--kind', '修正', '--source', 'skill-audit', '--id-prefix', 'skill-audit', '--title', '直す', '--diff-file', str(self.diff), '--target', self.target, '--dest-dir', str(dest), *args)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def table(self):
        dest = self.root / 'dest'
        dest.mkdir(exist_ok=True)
        (dest / 'table.md').write_text('| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | old | 記載あり | `/abs/else.md:1` |\n', encoding='utf-8')

    def test_missing_count(self):
        self.assertEqual(self.run_script('count.sh').stdout, 'changes\t0\t0\t\n')
        self.assertFalse(self.log.exists())

    def test_append_and_daily_sequence(self):
        a = self.new()
        b = self.new('--id-prefix', 'memory-audit', '--kind', '直してよい')
        self.assertTrue(a.endswith('-01'))
        self.assertTrue(b.endswith('-02'))
        self.assertRegex(a, r'^会話-\d{4}-\d{2}-\d{2}-01$')
        self.assertRegex(b, r'^memory-audit-\d{4}-\d{2}-\d{2}-\d{6}-02$')
        text = self.log.read_text()
        self.assertIn('要確認（会話で利用者に示して承認を受ける）', text)
        self.assertEqual(text.count('# 直したいことの記録\n'), 1)
        self.assertEqual(self.run_script('count.sh').stdout, f'changes\t2\t1\t{a}\n')

    def test_concurrent_ids(self):
        with ThreadPoolExecutor(2) as pool:
            ids = list(pool.map(lambda _: self.new(), range(2)))
        self.assertEqual(len(set(ids)), 2)
        self.assertEqual({x[-2:] for x in ids}, {'01', '02'})
        self.assertFalse((self.log.parent / '.lock').exists())

    def test_mark_and_missing_id(self):
        a = self.new()
        b = self.new()
        self.assertEqual(self.run_script('changes.sh', 'mark', a, 'done', '直した').returncode, 0)
        self.assertEqual(self.run_script('changes.sh', 'mark', b, 'skip', '一致しない').returncode, 0)
        self.assertIn('- 状態: 対応済み（', self.log.read_text())
        self.assertIn('一致しない）', self.log.read_text())
        self.assertEqual(self.run_script('count.sh').stdout, 'changes\t0\t0\t\n')
        self.assertEqual(self.run_script('changes.sh', 'mark', 'unknown', 'done', '直した').returncode, 1)

    def test_fenced_diff_does_not_create_entries(self):
        self.diff.write_text('```\n## 2000-01-01 00:00 fake-01\n- 状態: 未対応\n- 区分: 要確認\n', encoding='utf-8')
        a = self.new()
        self.assertIn('````diff\n', self.log.read_text())
        self.assertEqual(self.run_script('count.sh').stdout, f'changes\t1\t1\t{a}\n')

    def test_markdown_context_fence_is_preserved(self):
        self.diff.write_text('--- /abs/x.md\n+++ /abs/x.md\n@@ -1,3 +1,3 @@\n ```\n-old\n+new\n ```\n')
        a = self.new()
        self.assertIn('````diff\n', self.log.read_text())
        self.assertEqual(self.run_script('count.sh').stdout, f'changes\t1\t1\t{a}\n')
        self.assertEqual(self.run_script('changes.sh', 'mark', a, 'done', '直した').returncode, 0)
        self.assertIn(' ```\n-old\n+new\n ```\n````', self.log.read_text())

    def test_section_does_not_split_entry(self):
        f = self.root / 'section'
        f.write_text('## 消える記述の行き先\n\n| 表 |\n', encoding='utf-8')
        self.new('--section-file', str(f))
        self.assertIn('### 消える記述の行き先', self.log.read_text())

    def test_missing_destinations_requires_confirmation(self):
        self.propose()
        self.assertIn('- 区分: 要確認（', self.log.read_text())

    def test_safe_change(self):
        self.table()
        self.propose()
        self.assertIn('- 区分: 直してよい\n', self.log.read_text())

    def test_complete_destination_can_be_applied(self):
        self.table()
        dest = self.root / 'dest'
        moved = self.root / 'destination file.md'
        moved.write_text('existing\n')
        (dest / 'after.md').write_text('existing\nold\n')
        (dest / 'moves.tsv').write_text(str(moved) + '\tafter.md\n')
        (dest / 'table.md').write_text('| No | 消える記述 | 行き先 | 場所 |\n| --- | --- | --- | --- |\n| 1 | old | 記載なし → この案で移す | 移し先 `' + str(moved) + '` |\n')
        self.propose('--allow-root', str(self.root))
        self.assertIn('- 区分: 直してよい\n', self.log.read_text())
        self.assertIn('--- ' + str(moved), self.log.read_text())
        self.assertEqual(moved.read_text(), 'existing\n')

    def test_safety_skill_requires_confirmation(self):
        self.table()
        self.target = '/abs/security-rules/SKILL.md'
        self.propose()
        self.assertIn('安全のための規則', self.log.read_text())
        self.assertIn('- 区分: 要確認（', self.log.read_text())

    def test_safety_removed_line_requires_confirmation(self):
        self.table()
        self.diff.write_text('--- /abs/x.md\n+++ /abs/x.md\n@@ -1 +0,0 @@\n-gitleaks\n')
        self.propose()
        self.assertIn('- 区分: 要確認（', self.log.read_text())

    def test_two_corrections_require_confirmation(self):
        self.table()
        for i in range(2):
            r = self.run_script('corrections.sh', 'add', '--id', str(i), '--kind', 'skill-audit/修正/x', '--target', self.target, '--correct', '正しくは残す')
            self.assertEqual(r.returncode, 0)
        self.propose('--category', 'skill-audit/修正/x')
        self.assertIn('2回訂正された', self.log.read_text())

    def test_explicit_reason_requires_confirmation(self):
        self.table()
        self.propose('--kind-reason', '判断に迷う')
        self.assertIn('- 区分: 要確認（判断に迷う', self.log.read_text())

    def test_diff_labels(self):
        old, new = self.root / 'old', self.root / 'new'
        old.write_text('a\n'); new.write_text('b\n')
        r = self.run_script('diff-label.sh', str(old), str(new), self.target)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.splitlines()[:2], ['--- ' + self.target, '+++ ' + self.target])

    def test_bad_args(self):
        self.assertEqual(self.run_script('new-change.sh', '--source', 'x').returncode, 2)
        self.assertEqual(self.run_script('changes.sh', 'mark', 'id', 'invalid', 'x').returncode, 2)

if __name__ == '__main__':
    unittest.main(verbosity=2)
