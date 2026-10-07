"""「承認して反映」（apply_lib.py とサーバーの /api/proposals/<名前>/apply）の検査。

一時フォルダを HOME・案の置き場所・台帳の置き場所にする。本物の置き場所と台帳には触れない。
"""

import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.realpath(__file__))
CORE = os.path.dirname(HERE)
SERVER = os.path.join(CORE, "server", "inbox_server.py")
sys.path.insert(0, os.path.join(CORE, "skills", "change-review", "scripts"))
import proposal_lib as pl  # noqa: E402
import approved as approved_mod  # noqa: E402
import apply_lib  # noqa: E402


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def udiff(old_text, new_text, path):
    """diff -u で差分を作り、見出しの2行を path にする（diff-label.sh と同じ形）。"""
    work = tempfile.mkdtemp(prefix="review-apply-diff.")
    try:
        a, b = os.path.join(work, "a"), os.path.join(work, "b")
        if old_text is None:
            a = "/dev/null"
        else:
            write(a, old_text)
        if new_text is None:
            b = "/dev/null"
        else:
            write(b, new_text)
        r = subprocess.run(["diff", "-u", a, b], stdout=subprocess.PIPE)
        lines = r.stdout.decode("utf-8").splitlines()
        lines[0] = "--- " + (path if old_text is not None else "/dev/null")
        lines[1] = "+++ " + (path if new_text is not None else "/dev/null")
        return "\n".join(lines)
    finally:
        shutil.rmtree(work)


def proposal(pid, targets, diff, heading="見出し", reason="検査のための変更。", note="", status="pending"):
    return ("---\nid: %s\nstatus: %s\ncreated: 2026-10-06 10:00\nsource: 検査\ntargets:\n%s\nnote: %s\n---\n\n"
            "# %s\n\n## 理由\n\n%s\n\n## 差分\n\n```diff\n%s\n```\n\n## 反映後の確かめ方\n\n確かめる。\n"
            % (pid, status, "".join("  - %s\n" % t for t in targets), json.dumps(note, ensure_ascii=False),
               heading, reason, diff))


class Base(unittest.TestCase):
    def setUp(self):
        self.work = os.path.realpath(tempfile.mkdtemp(prefix="review-apply-test."))
        self.home = os.path.join(self.work, "home")
        self.pdir = os.path.join(self.home, "claude-reports", "proposals")
        self.sdir = os.path.join(self.home, ".local", "state", "claude-review-inbox")
        os.makedirs(self.pdir)
        self.saved = dict(os.environ)
        os.environ["HOME"] = self.home
        os.environ["CLAUDE_REVIEW_PROPOSALS"] = self.pdir
        os.environ["CLAUDE_REVIEW_STATE"] = self.sdir
        self.seq = 0

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        for root, dirs, _ in os.walk(self.work):
            for d in dirs:
                os.chmod(os.path.join(root, d), 0o755)
        shutil.rmtree(self.work)

    def add(self, targets, diff, **kw):
        self.seq += 1
        pid = "2026-10-06-%02d" % self.seq
        name = "%s-case" % pid
        write(os.path.join(self.pdir, name + ".md"), proposal(pid, targets, diff, **kw))
        return name

    def path_of(self, name):
        return os.path.join(self.pdir, name + ".md")

    def ledger(self):
        p = os.path.join(self.sdir, "decisions.jsonl")
        return [json.loads(x) for x in read(p).splitlines() if x.strip()] if os.path.exists(p) else []

    def status(self, name):
        return pl.read_proposal(self.path_of(name)).status


class ApplyLibTest(Base):
    def apply(self, name, note=""):
        return apply_lib.approve_and_apply(self.pdir, name, note)

    def test_plain_diff_applied(self):
        t = os.path.join(self.home, ".claude", "skills", "x", "SKILL.md")
        write(t, "一\n二\n三\n")
        name = self.add([t], udiff("一\n二\n三\n", "一\n弐\n三\n", t))
        r = self.apply(name, "問題なし")
        self.assertEqual(r.kind, apply_lib.APPLIED, r.reason)
        self.assertEqual(read(t), "一\n弐\n三\n")
        text = read(self.path_of(name))
        self.assertIn("status: applied\n", text)
        self.assertRegex(text, r"\napplied: \d{4}-\d{2}-\d{2} \d{2}:\d{2}\n")
        # 台帳は approved の後に applied。どちらも本文の SHA-256 を持つ
        recs = self.ledger()
        self.assertEqual([x["to"] for x in recs], ["approved", "applied"])
        self.assertEqual(recs[-1]["sha256"], pl.body_sha256(text))
        # approved.py の判定は、反映済みの案を OK にも NG にも出さない
        ok, ng = approved_mod.judge(pl.list_proposals(self.pdir), pl.latest_decisions())
        self.assertEqual((ok, ng), ([], []))
        # 直す前の版が残る
        day = time.strftime("%Y-%m-%d")
        bak = os.path.join(self.pdir, ".backup", day, "2026-10-06-01__claude__skills__x__SKILL.md.bak")
        self.assertEqual(read(bak), "一\n二\n三\n")

    def test_twice_does_not_apply_twice(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\nb\n")
        name = self.add([t], udiff("a\nb\n", "a\nb\nc\n", t))
        self.assertEqual(self.apply(name).kind, apply_lib.APPLIED)
        with self.assertRaises(PermissionError):
            self.apply(name)
        self.assertEqual(read(t), "a\nb\nc\n")
        self.assertEqual([x["to"] for x in self.ledger()], ["approved", "applied"])

    def test_concurrent_presses(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\nb\n")
        name = self.add([t], udiff("a\nb\n", "a\nb\nc\n", t))
        results = []

        def press():
            try:
                results.append(self.apply(name).kind)
            except PermissionError:
                results.append("refused")
        threads = [threading.Thread(target=press) for _ in range(4)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        self.assertEqual(sorted(results), ["applied", "refused", "refused", "refused"])
        self.assertEqual(read(t), "a\nb\nc\n")

    def test_mismatch_holds_without_changes(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\nB\nc\n")  # 差分を作った後に書き換わった
        name = self.add([t], udiff("a\nb\nc\n", "a\nX\nc\n", t))
        r = self.apply(name, "見た")
        self.assertEqual(r.kind, apply_lib.MISMATCH)
        self.assertEqual(read(t), "a\nB\nc\n")
        text = read(self.path_of(name))
        self.assertIn("status: hold\n", text)
        self.assertIn("反映時に差分が今のファイルと一致しなかった", r.proposal.meta["note"])
        self.assertIn("承認時のメモ: 見た", r.proposal.meta["note"])
        self.assertEqual([x["to"] for x in self.ledger()], ["approved", "hold"])
        self.assertFalse(os.path.exists(os.path.join(self.pdir, ".backup")))

    def test_already_applied_content_is_mismatch(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\nX\nc\n")
        name = self.add([t], udiff("a\nb\nc\n", "a\nX\nc\n", t))
        self.assertEqual(self.apply(name).kind, apply_lib.MISMATCH)
        self.assertEqual(read(t), "a\nX\nc\n")

    def test_offset_allowed_only_when_unique(self):
        t = os.path.join(self.home, "notes.md")
        base = "".join("行%d\n" % i for i in range(1, 11))
        name = self.add([t], udiff(base, base.replace("行5\n", "五\n"), t))
        write(t, "先頭に足した行\n" + base)  # 1行ずれた
        self.assertEqual(self.apply(name).kind, apply_lib.APPLIED)
        self.assertIn("先頭に足した行\n行1\n", read(t))
        self.assertIn("行4\n五\n行6\n", read(t))
        # 同じ並びが2か所あってずれた場合は当てない
        t2 = os.path.join(self.home, "dup.md")
        block = "x\ny\nz\n"
        name2 = self.add([t2], udiff(block, "x\nY\nz\n", t2))
        write(t2, "前\n" + block + "間\n" + block)
        self.assertEqual(self.apply(name2).kind, apply_lib.MISMATCH)
        self.assertEqual(read(t2), "前\n" + block + "間\n" + block)

    def test_create_and_delete_files(self):
        idx = os.path.join(self.home, ".claude", "projects", "p", "memory", "MEMORY.md")
        mem = os.path.join(self.home, ".claude", "projects", "p", "memory", "old.md")
        new = os.path.join(self.home, ".claude", "projects", "p", "memory", "sub", "new.md")
        write(idx, "- [old](old.md)\n- [keep](keep.md)\n")
        write(mem, "古いメモリ\n")
        diff = "\n".join([
            # memory-audit の削除の形（+++ も同じパスで、範囲が +0,0）
            udiff("古いメモリ\n", None, mem).replace("+++ /dev/null", "+++ " + mem),
            udiff("- [old](old.md)\n- [keep](keep.md)\n", "- [keep](keep.md)\n- [new](sub/new.md)\n", idx),
            udiff(None, "新しいメモリ\n", new),
        ])
        name = self.add([mem, idx, new], diff)
        r = self.apply(name)
        self.assertEqual(r.kind, apply_lib.APPLIED, r.reason)
        self.assertFalse(os.path.exists(mem))
        self.assertEqual(read(idx), "- [keep](keep.md)\n- [new](sub/new.md)\n")
        self.assertEqual(read(new), "新しいメモリ\n")

    def test_failure_midway_restores_all(self):
        a = os.path.join(self.home, "a", "one.md")
        b = os.path.join(self.home, "b", "two.md")
        write(a, "1\n")
        write(b, "2\n")
        name = self.add([a, b], udiff("1\n", "一\n", a) + "\n" + udiff("2\n", "二\n", b))
        os.chmod(os.path.dirname(b), 0o555)  # 2つ目の置き換えで失敗させる
        r = self.apply(name)
        os.chmod(os.path.dirname(b), 0o755)
        self.assertEqual(r.kind, apply_lib.MISMATCH, r.reason)
        self.assertIn("元に戻した", r.reason)
        self.assertEqual(read(a), "1\n")
        self.assertEqual(read(b), "2\n")
        self.assertIn("status: hold\n", read(self.path_of(name)))
        self.assertEqual([x for x in os.listdir(os.path.dirname(a)) if x.startswith(".tmp")], [])

    def test_ledger_failure_restores(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\n")
        name = self.add([t], udiff("a\n", "b\n", t))
        orig = pl.append_ledger

        def fail_on_applied(pid, to, note, sha):
            if to == "applied":
                raise OSError("検査用の失敗")
            return orig(pid, to, note, sha)
        pl.append_ledger = fail_on_applied
        try:
            r = self.apply(name)
        finally:
            pl.append_ledger = orig
        self.assertEqual(r.kind, apply_lib.MISMATCH)
        self.assertEqual(read(t), "a\n")
        self.assertIn("status: hold\n", read(self.path_of(name)))

    def assert_needs_claude(self, name, target, before, word):
        # 画面のメモ欄には案の note が入っており、押すとその内容が送られる
        r = self.apply(name, pl.read_proposal(self.path_of(name)).meta.get("note", ""))
        self.assertEqual(r.kind, apply_lib.NEEDS_CLAUDE)
        self.assertIn(word, r.reason)
        self.assertEqual(self.status(name), "approved")
        if before is None:
            self.assertFalse(os.path.exists(target))
        else:
            self.assertEqual(read(target), before)
        # approved.py では承認済み（Claude が反映する）として扱える
        ok, _ = approved_mod.judge([pl.read_proposal(self.path_of(name))], pl.latest_decisions())
        self.assertEqual(ok, [self.path_of(name)])

    def test_not_auto_cases(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\nb\n")
        d = udiff("a\nb\n", "a\nc\n", t)
        self.assert_needs_claude(self.add([t], d, heading="直す（移し先の確認が必要）"), t, "a\nb\n", "移し先の確認")
        self.assert_needs_claude(self.add([t], d, note="No 2 は移さない"), t, "a\nb\n", "移さない")
        self.assert_needs_claude(self.add([t], d, reason="trash-skill.sh で退避する。"), t, "a\nb\n", "削除の手段")
        self.assert_needs_claude(self.add([t], "差分なし"), t, "a\nb\n", "差分を読み取れない")
        broken = d.replace("@@ -1,2 +1,2 @@", "@@ -1,5 +1,2 @@")
        self.assert_needs_claude(self.add([t], broken), t, "a\nb\n", "差分を読み取れない")
        other = os.path.join(self.home, "other.md")
        write(other, "a\nb\n")
        self.assert_needs_claude(self.add([t], udiff("a\nb\n", "a\nc\n", other)), other, "a\nb\n", "targets に無い")
        skill = os.path.join(self.home, ".claude", "skills", "y", "SKILL.md")
        write(skill, "x\n")
        self.assert_needs_claude(self.add([skill], udiff("x\n", None, skill)), skill, "x\n", "スキルの削除")
        skill_dir = os.path.dirname(skill)
        self.assert_needs_claude(self.add([skill_dir], udiff("x\n", None, skill)), skill, "x\n", "フォルダ")
        # 差分のブロックが無い案
        self.seq += 1
        name = "2026-10-06-%02d-case" % self.seq
        write(self.path_of(name), "---\nid: 2026-10-06-%02d\nstatus: pending\ntargets:\n  - %s\n---\n\n# 見出し\n" % (self.seq, t))
        self.assert_needs_claude(name, t, "a\nb\n", "差分のブロックが無い")

    def test_refuses_outside_home(self):
        outside = os.path.join(self.work, "outside.md")
        write(outside, "a\n")
        self.assert_needs_claude(self.add([outside], udiff("a\n", "b\n", outside)), outside, "a\n", "ホームの外")
        # .. で外へ出るパス
        dotdot = os.path.join(self.home, "..", "outside.md")
        self.assert_needs_claude(self.add([dotdot], udiff("a\n", "b\n", dotdot)), outside, "a\n", "..")
        # ホームの中のリンクが外を指す
        link = os.path.join(self.home, "link.md")
        os.symlink(outside, link)
        self.assert_needs_claude(self.add([link], udiff("a\n", "b\n", link)), outside, "a\n", "ホームの外")
        # フォルダのリンクの下に作る
        os.symlink(self.work, os.path.join(self.home, "outdir"))
        made = os.path.join(self.home, "outdir", "made.md")
        self.assert_needs_claude(self.add([made], udiff(None, "x\n", made)), os.path.join(self.work, "made.md"), None,
                                 "ホームの外")
        # 案の置き場所と台帳の置き場所には書かない
        rej = os.path.join(self.pdir, "rejections.md")
        write(rej, "x\n")
        self.assert_needs_claude(self.add([rej], udiff("x\n", "y\n", rej)), rej, "x\n", "台帳")

    def test_link_inside_home_is_allowed(self):
        real = os.path.join(self.home, ".claude2", "CLAUDE.md")
        link = os.path.join(self.home, ".claude", "CLAUDE.md")
        write(real, "規則\n")
        os.makedirs(os.path.dirname(link))
        os.symlink(real, link)
        name = self.add([link], udiff("規則\n", "規則\n追加\n", link))
        self.assertEqual(self.apply(name).kind, apply_lib.APPLIED)
        self.assertTrue(os.path.islink(link))
        self.assertEqual(read(real), "規則\n追加\n")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class ApplyServerTest(Base):
    def setUp(self):
        Base.setUp(self)
        self.port = free_port()
        env = dict(os.environ)
        env.update({"CLAUDE_REVIEW_PORT": str(self.port), "CLAUDE_REVIEW_SCAN_INTERVAL": "60",
                    "CLAUDE_REVIEW_NOTIFY_CMD": "/usr/bin/true"})
        self.proc = subprocess.Popen([sys.executable, SERVER], env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)
        self.proc.stdout.close()
        Base.tearDown(self)

    def request(self, method, path, body=None, headers=None, origin="same"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Host": "127.0.0.1:%d" % self.port}
        if origin == "same":
            h["Origin"] = "http://127.0.0.1:%d" % self.port
        elif origin:
            h["Origin"] = origin
        h.update(headers or {})
        conn.putrequest(method, path, skip_host=True)
        for k, v in h.items():
            conn.putheader(k, v)
        if body is not None:
            conn.putheader("Content-Length", str(len(body)))
        conn.endheaders(body)
        r = conn.getresponse()
        text = r.read().decode("utf-8")
        conn.close()
        return r.status, text, r

    def token(self):
        _, text, _ = self.request("GET", "/")
        return re.search(r'<meta name="review-token" content="([^"]+)">', text).group(1)

    def api_apply(self, name, token, note="", origin="same"):
        body = json.dumps({"note": note}).encode("utf-8")
        h = {"Content-Type": "application/json"}
        if token is not None:
            h["X-Review-Token"] = token
        status, text, _ = self.request("POST", "/api/proposals/%s/apply" % name, body, h, origin)
        try:
            return status, json.loads(text)
        except ValueError:
            return status, text

    def form_apply(self, name, token, origin="same"):
        body = urllib.parse.urlencode({"to": "apply", "note": "", "token": token}).encode("utf-8")
        return self.request("POST", "/p/%s/decide" % name, body,
                            {"Content-Type": "application/x-www-form-urlencoded"}, origin)

    def test_button_and_api(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\n")
        name = self.add([t], udiff("a\n", "b\n", t))
        _, text, _ = self.request("GET", "/")
        self.assertIn('value="apply" class="apply">承認して反映</button>', text)
        self.assertNotIn(">承認する<", text)
        self.assertIn('<input type="hidden" name="token" value="', text)
        tok = self.token()
        status, data = self.api_apply(name, tok)
        self.assertEqual(status, 200, data)
        self.assertEqual(data["result"], "applied")
        self.assertEqual(data["item"]["status"], "applied")
        self.assertIn("反映しました", data["message"])
        self.assertEqual(read(t), "b\n")
        # 二度目は反映済みとして断り、二重に当てない
        status, data = self.api_apply(name, tok)
        self.assertEqual(status, 409)
        self.assertEqual(read(t), "b\n")

    def test_needs_claude_and_hold_messages(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\n")
        tok = self.token()
        n1 = self.add([t], udiff("a\n", "b\n", t), heading="直す（移し先の確認が必要）")
        status, data = self.api_apply(n1, tok)
        self.assertEqual((status, data["result"], data["item"]["status"]), (200, "needs_claude", "approved"))
        self.assertIn("Claude による反映が必要", data["message"])
        _, text, _ = self.request("GET", "/?status=approved")
        self.assertIn('<p class="needs">Claude による反映が必要です（移し先の確認が必要な案である）', text)
        n2 = self.add([t], udiff("x\n", "y\n", t))
        status, data = self.api_apply(n2, tok)
        self.assertEqual((data["result"], data["item"]["status"]), ("hold", "hold"))
        self.assertIn("一致しなかった", data["message"])
        self.assertEqual(read(t), "a\n")
        # フォームの POST（JavaScript が無いとき）でも結果が案の画面に出る
        n3 = self.add([t], udiff("a\n", "c\n", t))
        status, _, r = self.form_apply(n3, tok)
        self.assertEqual(status, 303)
        self.assertEqual(r.getheader("Location"), "/p/%s?done=applied" % n3)
        _, text, _ = self.request("GET", r.getheader("Location"))
        self.assertIn("承認して反映しました", text)
        self.assertEqual(read(t), "c\n")
        n4 = self.add([t], udiff("zzz\n", "c\n", t))
        _, _, r = self.form_apply(n4, tok)
        _, text, _ = self.request("GET", r.getheader("Location"))
        self.assertIn("反映せずに保留にしました", text)

    def test_rejects_other_origin_and_bad_token(self):
        t = os.path.join(self.home, "notes.md")
        write(t, "a\n")
        name = self.add([t], udiff("a\n", "b\n", t))
        tok = self.token()
        for origin in ("http://evil.example", "http://127.0.0.1:1", None):
            status, _ = self.api_apply(name, tok, origin=origin)
            self.assertEqual(status, 403, origin)
            status, _, _ = self.form_apply(name, tok, origin=origin)
            self.assertEqual(status, 403, origin)
        for bad in (None, "", "x" * 43):
            status, _ = self.api_apply(name, bad)
            self.assertEqual(status, 403, bad)
            status, _, _ = self.form_apply(name, bad or "")
            self.assertEqual(status, 403, bad)
        # text/plain の本文（別のページのフォームから送れる形）も断る
        status, _, _ = self.request("POST", "/api/proposals/%s/apply" % name, b'{"note":""}',
                                    {"Content-Type": "text/plain", "X-Review-Token": tok})
        self.assertEqual(status, 415)
        self.assertEqual(read(t), "a\n")
        self.assertEqual(self.status(name), "pending")
        self.assertEqual(self.ledger(), [])

    def test_listens_only_on_loopback(self):
        out = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(self.proc.pid), "-iTCP", "-sTCP:LISTEN"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode("utf-8", "replace")
        if not out.strip():
            self.skipTest("lsof で待ち受けを確かめられません")
        listens = [x for x in out.splitlines() if "LISTEN" in x]
        self.assertTrue(listens, out)
        for x in listens:
            self.assertIn("127.0.0.1:%d" % self.port, x)


if __name__ == "__main__":
    unittest.main(verbosity=2)
