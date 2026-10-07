"""approved.py（承認済みの判定）と count.sh・new-proposal.sh・diff-label.sh の検査。"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "skills", "change-review", "scripts")
sys.path.insert(0, SCRIPTS)
import proposal_lib as pl  # noqa: E402

TEXT = """---
id: {id}
status: {status}
created: 2026-10-05 10:00
source: 検査
targets:
  - /tmp/x.md
---

# 見出し {id}

本文
"""


def wr(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def rd(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class ApprovedTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="review-approved-test.")
        self.pdir = os.path.join(self.work, "proposals")
        self.sdir = os.path.join(self.work, "state")
        os.makedirs(self.pdir)
        self.env = dict(os.environ, CLAUDE_REVIEW_PROPOSALS=self.pdir, CLAUDE_REVIEW_STATE=self.sdir)
        os.environ["CLAUDE_REVIEW_PROPOSALS"] = self.pdir
        os.environ["CLAUDE_REVIEW_STATE"] = self.sdir

    def tearDown(self):
        shutil.rmtree(self.work)

    def put(self, pid, status, name=None):
        path = os.path.join(self.pdir, (name or pid + "-x") + ".md")
        with open(path, "w", encoding="utf-8") as f:
            f.write(TEXT.format(id=pid, status=status))
        return path

    def run_script(self, *args):
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "approved.py")] + list(args), env=self.env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return [x.split("\t") for x in r.stdout.splitlines()]

    def test_with_ledger(self):
        path = self.put("2026-10-05-01", "pending")
        pl.decide(self.pdir, os.path.basename(path), "approved", "")
        self.assertEqual(self.run_script(), [["OK", path]])
        self.assertEqual(self.run_script("--paths"), [[path]])

    def test_without_ledger(self):
        path = self.put("2026-10-05-01", "approved")  # ファイルだけ approved に書き換えた
        out = self.run_script()
        self.assertEqual(out[0][:2], ["NG", path])
        self.assertIn("台帳に記録がない", out[0][2])
        self.assertEqual(self.run_script("--paths"), [])

    def test_body_rewritten(self):
        path = self.put("2026-10-05-01", "pending")
        pl.decide(self.pdir, os.path.basename(path), "approved", "")
        with open(path, "a", encoding="utf-8") as f:
            f.write("後から足した行\n")
        out = self.run_script()
        self.assertEqual(out[0][:2], ["NG", path])
        self.assertIn("SHA-256", out[0][2])

    def test_frontmatter_only_change_keeps_ok(self):
        path = self.put("2026-10-05-01", "pending")
        pl.decide(self.pdir, os.path.basename(path), "approved", "")
        text = rd(path).replace("source: 検査", "source: 書き換え")
        wr(path, text)
        self.assertEqual(self.run_script(), [["OK", path]])

    def test_latest_not_approved(self):
        path = self.put("2026-10-05-01", "pending")
        pl.decide(self.pdir, os.path.basename(path), "approved", "")
        pl.decide(self.pdir, os.path.basename(path), "hold", "")
        # ファイルの status だけを approved に書き換える
        text = rd(path).replace("status: hold", "status: approved")
        wr(path, text)
        out = self.run_script()
        self.assertEqual(out[0][:2], ["NG", path])
        self.assertIn("approved ではない（hold）", out[0][2])

    def test_other_status_ignored_and_broken_ledger_line(self):
        self.put("2026-10-05-01", "pending")
        self.put("2026-10-05-02", "applied")
        os.makedirs(self.sdir)
        with open(os.path.join(self.sdir, "decisions.jsonl"), "w") as f:
            f.write("壊れた行\n" + json.dumps({"id": "2026-10-05-01", "to": "approved", "sha256": "x"}) + "\n")
        self.assertEqual(self.run_script(), [])

    def test_count(self):
        def count():
            r = subprocess.run(["bash", os.path.join(SCRIPTS, "count.sh")], env=self.env,
                               stdout=subprocess.PIPE, universal_newlines=True)
            return r.stdout
        self.assertEqual(count(), "pending\t0\t\napproved\t0\n")
        self.put("2026-10-05-02", "pending")
        self.put("2026-10-04-09", "pending")
        self.put("2026-10-05-03", "approved")
        self.put("2026-10-05-04", "applied")
        self.put("2026-10-05-05", "rejected")
        wr(os.path.join(self.pdir, "2026-10-05-06-broken.md"), "status: pending\n")
        pl.ensure_rejections(self.pdir)
        self.assertEqual(count(), "pending\t2\t2026-10-04-09\napproved\t1\n")

    def test_new_proposal_and_diff_label(self):
        old = os.path.join(self.work, "old.md")
        new = os.path.join(self.work, "new.md")
        wr(old, "a\nb\n")
        wr(new, "a\nc\n")
        r = subprocess.run(["bash", os.path.join(SCRIPTS, "diff-label.sh"), old, new, "/abs/target.md"],
                           stdout=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.returncode, 1)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[:2], ["--- /abs/target.md", "+++ /abs/target.md"])
        self.assertIn("-b", lines)
        self.assertIn("+c", lines)
        dfile = os.path.join(self.work, "d.diff")
        wr(dfile, r.stdout + "```\n")  # 区切りを含む差分
        ids = []
        for _ in range(2):
            p = subprocess.run(["bash", os.path.join(SCRIPTS, "new-proposal.sh"), "--source", "memory-audit",
                                "--title", "見出し", "--diff-file", dfile, "--target", "/abs/target.md",
                                "--reason", "理由の文", "--slug", "Memory Fix!"],
                               env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            ids.append(p.stdout.strip())
        self.assertEqual(ids[0][-2:], "01")
        self.assertEqual(ids[1][-2:], "02")
        props = pl.list_proposals(self.pdir)
        self.assertEqual([x.id for x in props], ids)
        p = props[0]
        self.assertEqual(p.name, ids[0] + "-memory-fix.md")
        self.assertEqual(p.status, "pending")
        self.assertEqual(p.meta["source"], "memory-audit")
        self.assertEqual(p.meta["targets"], ["/abs/target.md"])
        self.assertEqual(p.meta["note"], "")
        self.assertEqual(p.heading, "見出し")
        self.assertIn("````diff\n--- /abs/target.md", p.body)
        self.assertIn("```\n````\n", p.body)
        self.assertIn("## 反映後の確かめ方", p.body)
        self.assertFalse(os.path.exists(os.path.join(self.pdir, ".lock")))
        bad = subprocess.run(["bash", os.path.join(SCRIPTS, "new-proposal.sh"), "--source", "x"],
                             env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(bad.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
