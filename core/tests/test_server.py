"""inbox_server.py の検査。一時フォルダを案の置き場所にしてサーバーを起動し、HTTP で確かめる。

通知のコマンドは CLAUDE_REVIEW_NOTIFY_CMD で差し替え、呼ばれた引数をファイルへ記録する。
"""

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.realpath(__file__))
CORE = os.path.dirname(HERE)
SERVER = os.path.join(CORE, "server", "inbox_server.py")
sys.path.insert(0, os.path.join(CORE, "skills", "change-review", "scripts"))
import proposal_lib as pl  # noqa: E402

PROPOSAL = """---
id: {id}
status: {status}
created: 2026-10-05 10:00
source: 検査
targets:
  - /tmp/target-{id}.md
---

# 見出し {id}

## 理由

<script>alert(1)</script> を含む本文。

## 差分

```diff
--- /tmp/target-{id}.md
+++ /tmp/target-{id}.md
@@ -1,2 +1,2 @@
 文脈の行
-消す行
+足す行
```
"""


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.mkdtemp(prefix="review-inbox-test.")
        cls.pdir = os.path.join(cls.work, "proposals")
        cls.sdir = os.path.join(cls.work, "state")
        os.makedirs(cls.pdir)
        cls.notify_log = os.path.join(cls.work, "notify.log")
        notify = os.path.join(cls.work, "notify.sh")
        write(notify, '#!/bin/bash\nprintf "%s\\t%s\\t%s\\n" "$1" "$2" "$3" >>"' + cls.notify_log + '"\n')
        os.chmod(notify, 0o755)
        write(os.path.join(cls.pdir, "2026-10-05-01-first.md"), PROPOSAL.format(id="2026-10-05-01", status="pending"))
        write(os.path.join(cls.pdir, "2026-10-05-02-second.md"), PROPOSAL.format(id="2026-10-05-02", status="pending"))
        write(os.path.join(cls.pdir, "2026-10-04-01-done.md"), PROPOSAL.format(id="2026-10-04-01", status="applied"))
        write(os.path.join(cls.work, "secret.md"), PROPOSAL.format(id="2026-01-01-01", status="pending"))
        cls.port = free_port()
        cls.env = dict(os.environ)
        cls.env.update({
            "CLAUDE_REVIEW_PORT": str(cls.port),
            "CLAUDE_REVIEW_PROPOSALS": cls.pdir,
            "CLAUDE_REVIEW_STATE": cls.sdir,
            "CLAUDE_REVIEW_SCAN_INTERVAL": "0.2",
            "CLAUDE_REVIEW_NOTIFY_CMD": notify,
            # 本物の ~/claude-reports を読まないよう、レポートの置き場所も一時フォルダにする（最初は作らない）。
            "CLAUDE_REPORTS_ROOT": os.path.join(cls.work, "reports"),
            "CLAUDE_REPORTS_STATE": os.path.join(cls.work, "rstate"),
            # 本物の ~/.claude/skills を読まないよう、スキルの置き場所も一時フォルダにする（最初は作らない）。
            # リンクの先を「~/」で出すことを確かめるため、HOME も一時フォルダにする。
            "CLAUDE_SKILLS_DIR": os.path.join(cls.work, "skills"),
            "CLAUDE_SKILLS_EXCLUDE": "excluded-by-env, other",
            "HOME": os.path.realpath(cls.work),
        })
        cls.skills = os.path.join(cls.work, "skills")
        os.environ["CLAUDE_REVIEW_PROPOSALS"] = cls.pdir
        os.environ["CLAUDE_REVIEW_STATE"] = cls.sdir
        cls.proc = cls.start()

    @classmethod
    def start(cls):
        proc = subprocess.Popen([sys.executable, SERVER], env=cls.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", cls.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        # 初回の走査が終わるのを待つ
        for _ in range(100):
            if os.path.exists(os.path.join(cls.sdir, "notified.json")):
                break
            time.sleep(0.05)
        return proc

    @classmethod
    def stop(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        cls.proc.stdout.close()

    @classmethod
    def tearDownClass(cls):
        cls.stop()
        shutil.rmtree(cls.work)

    # ---- 送受信 ----
    def request(self, method, path, body=None, host=None, origin="same", referer=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Host": host or "127.0.0.1:%d" % self.port}
        if origin == "same":
            headers["Origin"] = "http://127.0.0.1:%d" % self.port
        elif origin:
            headers["Origin"] = origin
        if referer:
            headers["Referer"] = referer
        data = None
        if body is not None:
            data = urllib.parse.urlencode(body).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        conn.putrequest(method, path, skip_host=True)
        for k, v in headers.items():
            conn.putheader(k, v)
        if data is not None:
            conn.putheader("Content-Length", str(len(data)))
        conn.endheaders(data)
        r = conn.getresponse()
        text = r.read().decode("utf-8")
        conn.close()
        return r.status, text, r

    def request_json(self, path, obj, ctype="application/json", **kw):
        """JSON の本文で POST する。obj が bytes ならそのまま送る。"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        data = obj if isinstance(obj, bytes) else json.dumps(obj).encode("utf-8")
        headers = {"Host": kw.get("host") or "127.0.0.1:%d" % self.port, "Content-Type": ctype,
                   "Content-Length": str(len(data))}
        origin = kw.get("origin", "same")
        if origin == "same":
            headers["Origin"] = "http://127.0.0.1:%d" % self.port
        elif origin:
            headers["Origin"] = origin
        headers.update(kw.get("headers") or {})
        conn.putrequest("POST", path, skip_host=True)
        for k, v in headers.items():
            conn.putheader(k, v)
        conn.endheaders(data)
        r = conn.getresponse()
        text = r.read().decode("utf-8")
        conn.close()
        # Host・Origin の確認で拒んだときは、API でも HTML の 403 を返す（既存の拒否と同じ）
        if not r.getheader("Content-Type", "").startswith("application/json"):
            return r.status, text, r
        return r.status, json.loads(text), r

    def api_decide(self, name, to, note="", **kw):
        return self.request_json("/api/proposals/%s/decide" % name, {"to": to, "note": note}, **kw)

    def decide(self, name, to, note="", **kw):
        return self.request("POST", "/p/%s/decide" % name, {"to": to, "note": note}, **kw)

    def ledger(self):
        path = os.path.join(self.sdir, "decisions.jsonl")
        if not os.path.exists(path):
            return []
        return [json.loads(x) for x in read(path).splitlines() if x.strip()]

    def notifications(self):
        if not os.path.exists(self.notify_log):
            return []
        return [x.split("\t") for x in read(self.notify_log).splitlines()]

    def wait_notifications(self, n):
        for _ in range(100):
            if len(self.notifications()) >= n:
                break
            time.sleep(0.05)
        return self.notifications()

    # ---- 検査 ----
    def test_01_first_start_does_not_notify(self):
        time.sleep(0.6)
        self.assertEqual(self.notifications(), [])
        data = json.loads(read(os.path.join(self.sdir, "notified.json")))
        self.assertEqual(sorted(data["notified"]), ["2026-10-05-01", "2026-10-05-02"])
        self.assertTrue(os.path.exists(os.path.join(self.pdir, "rejections.md")))

    def test_02_list(self):
        status, text, _ = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn('lang="ja"', text)
        self.assertIn('承認待ち（<span class="count">2</span>件）', text)
        self.assertIn('反映済み（<span class="count">1</span>件）', text)
        self.assertIn("2026-10-05-01", text)
        self.assertIn("見出し 2026-10-05-02", text)
        self.assertIn("/tmp/target-2026-10-05-01.md", text)
        self.assertIn("2026-10-05 10:00", text)
        self.assertNotIn("2026-10-04-01", text.split('id="cards"')[1])
        # カードに理由・差分（承認待ちでは開く）・メモ欄・ボタン・出した元を出す
        self.assertIn('<article class="card" id="2026-10-05-01"', text)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt; を含む本文。", text)
        self.assertNotIn("<script>alert", text)
        self.assertIn('<details class="diff" open>', text)
        self.assertIn('<span class="add">+足す行</span>', text)
        self.assertIn('action="/p/2026-10-05-01-first/decide"', text)
        self.assertIn("<dt>出した元</dt><dd>検査</dd>", text)
        self.assertIn('<script src="/static/app.js" defer></script>', text)
        # 接続が切れたときの帯は、最初は隠しておく
        self.assertIn('<p class="offline" id="offline" role="alert" hidden>'
                      'サーバーに接続できません。再接続を試みています</p>', text)
        self.assertNotIn("onclick", text)
        self.assertNotIn("rejections", text)
        self.assertNotIn("http://", text.replace("http://127.0.0.1", ""))  # 外部の資源を読まない
        status, text, _ = self.request("GET", "/?status=applied")
        self.assertIn("見出し 2026-10-04-01", text)
        self.assertIn('<details class="diff">', text)  # 承認待ち以外では閉じる
        self.assertNotIn("<textarea", text)  # 反映済みは読むだけ
        self.assertNotIn("<button", text)
        status, text, _ = self.request("GET", "/?status=hold")
        self.assertIn("保留の変更はありません。", text)

    def test_03_detail_escape_and_diff(self):
        status, text, _ = self.request("GET", "/p/2026-10-05-01-first")
        self.assertEqual(status, 200)
        self.assertNotIn("<script>", text)
        self.assertIn("&lt;script&gt;", text)
        self.assertIn('<span class="add">+足す行</span>', text)
        self.assertIn('<span class="del">-消す行</span>', text)
        self.assertIn('<span class=""> 文脈の行</span>', text)
        for label in ("承認して反映", "保留にする", "却下する"):
            self.assertIn(label, text)
        status, text, _ = self.request("GET", "/p/2026-10-04-01-done")
        self.assertIn("反映済みのため", text)
        self.assertNotIn("<form", text)

    def test_04_transitions(self):
        name = "2026-10-05-01-first"
        path = os.path.join(self.pdir, name + ".md")
        before = read(path)
        status, _, r = self.decide(name, "approved", "問題なし")
        self.assertEqual(status, 303)
        self.assertEqual(r.getheader("Location"), "/p/%s?done=approved" % name)
        after = read(path)
        self.assertIn("status: approved\n", after)
        self.assertIn('note: "問題なし"\n', after)
        self.assertRegex(after, r"decided: \d{4}-\d{2}-\d{2} \d{2}:\d{2}\n")
        # 他の行は変えない
        self.assertEqual(pl.split_frontmatter(before)[1], pl.split_frontmatter(after)[1])
        for key in ("id: 2026-10-05-01", "created: 2026-10-05 10:00", "source: 検査", "  - /tmp/target-2026-10-05-01.md"):
            self.assertIn(key + "\n", after)
        rec = self.ledger()[-1]
        self.assertEqual((rec["id"], rec["to"], rec["note"]), ("2026-10-05-01", "approved", "問題なし"))
        self.assertEqual(rec["sha256"], pl.body_sha256(after))
        self.assertIn("T", rec["at"])

        self.decide(name, "hold", "後で見る")
        self.assertIn("status: hold\n", read(path))
        self.assertEqual(self.ledger()[-1]["to"], "hold")

        # 却下で否認リストに1行、戻すと消える
        self.decide(name, "rejected", "趣旨が | 違う")
        rej = read(os.path.join(self.pdir, "rejections.md"))
        self.assertIn("| ID | 対象 | 否認した変更の要約 | 理由（メモ） | 否認日 |", rej)
        rows = [x for x in rej.splitlines() if x.startswith("| 2026-10-05-01 ")]
        self.assertEqual(len(rows), 1)
        self.assertIn("/tmp/target-2026-10-05-01.md | 見出し 2026-10-05-01 | 趣旨が \\| 違う |", rows[0])
        self.decide(name, "rejected", "理由を直した")
        rej = read(os.path.join(self.pdir, "rejections.md"))
        self.assertEqual(len([x for x in rej.splitlines() if x.startswith("| 2026-10-05-01 ")]), 1)
        self.assertIn("理由を直した", rej)
        self.decide(name, "pending")
        rej = read(os.path.join(self.pdir, "rejections.md"))
        self.assertNotIn("2026-10-05-01", rej)
        self.assertIn("status: pending\n", read(path))
        self.assertEqual([r["to"] for r in self.ledger()[-5:]], ["approved", "hold", "rejected", "rejected", "pending"])
        # 一時ファイルを残さない
        self.assertEqual([x for x in os.listdir(self.pdir) if x.startswith(".tmp")], [])

    def test_05_bad_transition(self):
        status, _, _ = self.decide("2026-10-05-02-second", "applied")
        self.assertEqual(status, 400)
        status, _, _ = self.decide("2026-10-04-01-done", "approved")
        self.assertEqual(status, 409)
        self.assertIn("status: applied\n", read(os.path.join(self.pdir, "2026-10-04-01-done.md")))

    def test_06_origin_rejected(self):
        name = "2026-10-05-02-second"
        n = len(self.ledger())
        cases = [
            dict(origin="http://evil.example"),
            dict(origin="http://127.0.0.1:1"),
            dict(origin=None),  # Origin も Referer も無い
            dict(origin=None, referer="http://evil.example/p/x"),
            dict(origin=None, referer="http://127.0.0.1:%d.evil.example/" % self.port),
        ]
        for kw in cases:
            status, _, _ = self.decide(name, "approved", **kw)
            self.assertEqual(status, 403, kw)
        self.assertIn("status: pending\n", read(os.path.join(self.pdir, name + ".md")))
        self.assertEqual(len(self.ledger()), n)
        # Referer が自分自身なら受け付ける（Origin が無いブラウザ）
        status, _, _ = self.decide(name, "hold", origin=None, referer="http://localhost:%d/p/%s" % (self.port, name),
                                   host="localhost:%d" % self.port)
        self.assertEqual(status, 303)
        self.decide(name, "pending")

    def test_07_host_rejected(self):
        for host in ("evil.example", "evil.example:%d" % self.port, "127.0.0.1", "127.0.0.1:1"):
            status, _, _ = self.request("GET", "/", host=host)
            self.assertEqual(status, 403, host)
            status, _, _ = self.decide("2026-10-05-02-second", "approved", host=host)
            self.assertEqual(status, 403, host)
        status, _, _ = self.request("GET", "/", host="localhost:%d" % self.port)
        self.assertEqual(status, 200)

    def test_08_path_traversal(self):
        for p in ("/p/..%2Fsecret", "/p/../secret", "/p/%2E%2E%2Fsecret", "/p/..", "/p/rejections",
                  "/p/2026-10-05-01-first%2F..%2F..%2Fsecret", "/p/%2Fetc%2Fpasswd"):
            status, text, _ = self.request("GET", p)
            self.assertEqual(status, 404, p)
            self.assertNotIn("2026-01-01-01", text)
        for name in ("..%2Fsecret", "%2E%2E%2Fsecret", "rejections"):
            status, _, _ = self.request("POST", "/p/%s/decide" % name, {"to": "approved", "note": ""})
            self.assertEqual(status, 404, name)
        self.assertIn("status: pending\n", read(os.path.join(self.work, "secret.md")))

    def test_09_notify_only_new(self):
        self.assertEqual(self.notifications(), [])
        write(os.path.join(self.pdir, "2026-10-05-03-third.md"), PROPOSAL.format(id="2026-10-05-03", status="pending"))
        got = self.wait_notifications(1)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0], ["承認待ちが届きました", "見出し 2026-10-05-03",
                                  "http://127.0.0.1:%d/?status=pending#2026-10-05-03" % self.port])
        time.sleep(0.6)
        self.assertEqual(len(self.notifications()), 1)  # 同じ案を二度通知しない
        # 同時に増えた分は1件にまとめる
        write(os.path.join(self.pdir, "2026-10-05-04-a.md"), PROPOSAL.format(id="2026-10-05-04", status="pending"))
        write(os.path.join(self.pdir, "2026-10-05-05-b.md"), PROPOSAL.format(id="2026-10-05-05", status="pending"))
        got = self.wait_notifications(2)
        self.assertEqual(len(got), 2)
        self.assertEqual(got[1], ["承認待ちが届きました", "承認待ちが2件届きました", "http://127.0.0.1:%d/" % self.port])
        # pending でないものは通知しない
        write(os.path.join(self.pdir, "2026-10-05-06-c.md"), PROPOSAL.format(id="2026-10-05-06", status="hold"))
        time.sleep(0.6)
        self.assertEqual(len(self.notifications()), 2)

    def test_10_restart_notifies_only_new(self):
        type(self).stop()
        write(os.path.join(self.pdir, "2026-10-05-07-d.md"), PROPOSAL.format(id="2026-10-05-07", status="pending"))
        type(self).proc = type(self).start()
        got = self.wait_notifications(3)
        self.assertEqual(len(got), 3)
        self.assertEqual(got[2][1], "見出し 2026-10-05-07")


    def test_11_api_list(self):
        status, text, r = self.request("GET", "/api/proposals")
        self.assertEqual(status, 200)
        self.assertTrue(r.getheader("Content-Type").startswith("application/json"))
        items = dict((x["id"], x) for x in json.loads(text))
        it = items["2026-10-05-02"]
        self.assertEqual(it["slug"], "2026-10-05-02-second")
        self.assertEqual(it["source"], "検査")
        self.assertEqual(it["reason"], "<script>alert(1)</script> を含む本文。")
        self.assertEqual(it["diff"], [
            {"kind": "header", "text": "--- /tmp/target-2026-10-05-02.md"},
            {"kind": "header", "text": "+++ /tmp/target-2026-10-05-02.md"},
            {"kind": "header", "text": "@@ -1,2 +1,2 @@"},
            {"kind": "context", "text": " 文脈の行"},
            {"kind": "del", "text": "-消す行"},
            {"kind": "add", "text": "+足す行"},
        ])
        self.assertEqual(it["sections"], [])  # 差分の節は差分の行だけなので、その他の本文に出さない
        self.assertIn("decided", it)

    def test_12_api_decide(self):
        name = "2026-10-05-02-second"
        path = os.path.join(self.pdir, name + ".md")
        n = len(self.ledger())
        status, data, r = self.api_decide(name, "approved", "問題なし")
        self.assertEqual(status, 200)
        self.assertTrue(r.getheader("Content-Type").startswith("application/json"))
        self.assertEqual((data["id"], data["status"], data["note"]), ("2026-10-05-02", "approved", "問題なし"))
        self.assertRegex(data["decided"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")
        self.assertIn("status: approved\n", read(path))
        rec = self.ledger()[-1]
        self.assertEqual((rec["id"], rec["to"], rec["note"]), ("2026-10-05-02", "approved", "問題なし"))
        self.assertEqual(rec["sha256"], pl.body_sha256(read(path)))

        status, data, _ = self.api_decide(name, "hold", "後で")
        self.assertEqual((status, data["status"]), (200, "hold"))
        status, data, _ = self.api_decide(name, "rejected", "趣旨が違う")
        self.assertEqual((status, data["status"]), (200, "rejected"))
        rej = read(os.path.join(self.pdir, "rejections.md"))
        rows = [x for x in rej.splitlines() if x.startswith("| 2026-10-05-02 ")]
        self.assertEqual(len(rows), 1)
        self.assertIn("趣旨が違う", rows[0])
        # 元に戻す（直前の状態へ POST する）と否認リストから消える
        status, data, _ = self.api_decide(name, "pending", "")
        self.assertEqual((status, data["status"]), (200, "pending"))
        self.assertNotIn("2026-10-05-02", read(os.path.join(self.pdir, "rejections.md")))
        self.assertEqual([x["to"] for x in self.ledger()[n:]], ["approved", "hold", "rejected", "pending"])

        # 誤った要求
        status, data, _ = self.api_decide(name, "applied")
        self.assertEqual(status, 400)
        self.assertIn("error", data)
        status, data, _ = self.api_decide("2026-10-04-01-done", "approved")
        self.assertEqual(status, 409)
        status, data, _ = self.api_decide("2026-10-99-01-none", "approved")
        self.assertEqual(status, 404)
        status, data, _ = self.api_decide("..%2Fsecret", "approved")
        self.assertEqual(status, 404)
        status, data, _ = self.request_json("/api/proposals/%s/decide" % name, b"{not json")
        self.assertEqual(status, 400)
        status, data, _ = self.request_json("/api/proposals/%s/decide" % name, ["approved"])
        self.assertEqual(status, 400)
        self.assertIn("status: pending\n", read(path))
        self.assertEqual(len(self.ledger()), n + 4)

    def test_13_api_decide_rejects_content_type_and_origin(self):
        name = "2026-10-05-02-second"
        path = os.path.join(self.pdir, name + ".md")
        n = len(self.ledger())
        body = json.dumps({"to": "approved", "note": ""}).encode("utf-8")
        for ctype in ("application/x-www-form-urlencoded", "text/plain", "multipart/form-data; boundary=x", ""):
            status, data, _ = self.request_json("/api/proposals/%s/decide" % name, body, ctype=ctype)
            self.assertEqual(status, 415, ctype)
        status, _, _ = self.request_json("/api/proposals/%s/decide" % name, body,
                                         ctype="application/json; charset=utf-8")
        self.assertEqual(status, 200)  # charset 付きは受け付ける
        self.api_decide(name, "pending")
        n += 2
        for origin in ("http://evil.example", "http://127.0.0.1:1", None):
            conn_status = self.api_decide_raw(name, origin)
            self.assertEqual(conn_status, 403, origin)
        for host in ("evil.example:%d" % self.port, "127.0.0.1:1"):
            status = self.api_decide_raw(name, "same", host=host)
            self.assertEqual(status, 403, host)
        self.assertIn("status: pending\n", read(path))
        self.assertEqual(len(self.ledger()), n)

    def api_decide_raw(self, name, origin, host=None):
        """403 の応答は HTML のため、状態コードだけを返す。"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        data = json.dumps({"to": "approved", "note": ""}).encode("utf-8")
        conn.putrequest("POST", "/api/proposals/%s/decide" % name, skip_host=True)
        conn.putheader("Host", host or "127.0.0.1:%d" % self.port)
        if origin == "same":
            conn.putheader("Origin", "http://127.0.0.1:%d" % self.port)
        elif origin:
            conn.putheader("Origin", origin)
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(len(data)))
        conn.endheaders(data)
        r = conn.getresponse()
        r.read()
        conn.close()
        return r.status

    def test_14_static_and_csp(self):
        status, text, r = self.request("GET", "/static/app.js")
        self.assertEqual(status, 200)
        self.assertEqual(r.getheader("Content-Type"), "text/javascript; charset=utf-8")
        self.assertIn("/api/proposals", text)
        self.assertNotRegex(text, r"\.innerHTML\s*=")
        # 表示中は3秒ごとに取り直し、隠れている間は止め、表示とフォーカスの戻りですぐ取り直す
        self.assertIn("var POLL_MS = 3000;", text)
        self.assertIn("document.hidden", text)
        self.assertIn('addEventListener("visibilitychange", poll)', text)
        self.assertIn('addEventListener("focus", poll)', text)
        self.assertIn("件届きました", text)
        csp = r.getheader("Content-Security-Policy")
        for d in ("default-src 'none'", "script-src 'self'", "connect-src 'self'", "frame-ancestors 'none'"):
            self.assertIn(d, csp)
        self.assertNotIn("unsafe-inline'; script", csp)
        _, _, r = self.request("GET", "/")
        self.assertIn("script-src 'self'", r.getheader("Content-Security-Policy"))
        for p in ("/static/other.js", "/static/../inbox_server.py", "/static/%2E%2E%2Finbox_server.py", "/static/"):
            status, _, _ = self.request("GET", p)
            self.assertEqual(status, 404, p)
        status, _, _ = self.request("GET", "/static/app.js", host="evil.example")
        self.assertEqual(status, 403)

    # ---- 定期実行のレポート ----
    def token(self):
        _, text, _ = self.request("GET", "/")
        return text.split('<meta name="review-token" content="')[1].split('"')[0]

    def read_records(self):
        path = os.path.join(self.work, "rstate", "report-inbox", "read.txt")
        return read(path).splitlines() if os.path.exists(path) else []

    def mark(self, payload, token=None, **kw):
        return self.request_json("/api/reports/read", payload,
                                 headers={"X-Review-Token": self.token() if token is None else token}, **kw)

    def test_15_reports_toggle_hidden_without_jobs(self):
        root = os.path.join(self.work, "reports")
        self.assertFalse(os.path.exists(root))
        _, text, _ = self.request("GET", "/")
        self.assertNotIn('nav class="switch"', text)
        # 置き場所はあるが、ジョブが無い（承認待ちと「.」で始まるディレクトリだけ）
        os.makedirs(os.path.join(root, "proposals"))
        os.makedirs(os.path.join(root, ".hidden"))
        write(os.path.join(root, "top-level.md"), "x")
        _, text, _ = self.request("GET", "/")
        self.assertNotIn('nav class="switch"', text)

    def test_16_reports_list(self):
        root = os.path.join(self.work, "reports")
        os.makedirs(os.path.join(root, "repo-patrol"), exist_ok=True)
        os.makedirs(os.path.join(root, "feedback-mining"), exist_ok=True)
        os.makedirs(os.path.join(root, "memory-audit", ".snapshots"), exist_ok=True)
        for f in ("repo-patrol/2026-10-05.md", "repo-patrol/2026-10-07.md", "repo-patrol/2026-10-07-2.md",
                  "feedback-mining/2026-10-07.md"):
            write(os.path.join(root, f), "# %s\n" % f)
        write(os.path.join(root, "memory-audit", "2026-10-06.md"), "<script>alert(1)</script> & 本文\n")
        # 数えないもの
        for f in ("proposals/2026-10-09.md", ".hidden/2026-10-09.md", "memory-audit/.snapshots/2026-10-09.md",
                  "repo-patrol/notes.md", "repo-patrol/2026-10-09-x.md", "repo-patrol/2026-10-9.md"):
            write(os.path.join(root, f), "x")
        outside = os.path.join(self.work, "outside.md")
        write(outside, "外のファイル")
        os.symlink(outside, os.path.join(root, "repo-patrol", "2026-10-08.md"))

        _, text, _ = self.request("GET", "/")
        self.assertIn('<nav class="switch" aria-label="表示の切り替え"><a href="/" aria-current="page">承認待ち</a>'
                      '<a href="/reports">レポート（未読 <span class="unread-count">5</span> 件）</a></nav>', text)
        status, text, r = self.request("GET", "/reports")
        self.assertEqual(status, 200)
        self.assertIn('<a href="/reports" aria-current="page">', text)
        self.assertIn('未読（<span class="count">5</span>件）', text)
        self.assertIn('すべて（<span class="count">5</span>件）', text)
        self.assertIn('<script src="/static/reports.js" defer></script>', text)
        self.assertIn("未読をすべて既読にする", text)
        keys = [x.split('"')[0] for x in text.split('data-path="')[1:]]
        self.assertEqual(keys, ["repo-patrol/2026-10-07-2.md", "feedback-mining/2026-10-07.md",
                                "repo-patrol/2026-10-07.md", "memory-audit/2026-10-06.md",
                                "repo-patrol/2026-10-05.md"])
        self.assertNotIn("<script>alert", text)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt; &amp; 本文", text)
        self.assertNotIn("外のファイル", text)
        self.assertIn('<pre class="report-body">', text)
        self.assertIn("script-src 'self'", r.getheader("Content-Security-Policy"))
        status, text, _ = self.request("GET", "/static/reports.js")
        self.assertEqual(status, 200)
        self.assertNotRegex(text, r"\.innerHTML\s*=")

    def test_17_reports_mark_read(self):
        root = os.path.realpath(os.path.join(self.work, "reports"))
        status, data, _ = self.mark({"paths": ["repo-patrol/2026-10-07-2.md"]})
        self.assertEqual(status, 200)
        self.assertEqual(data, {"marked": 1, "counts": {"unread": 4, "all": 5}})
        self.assertEqual(self.read_records(), [root + "/repo-patrol/2026-10-07-2.md"])
        # 二重に足さない
        status, data, _ = self.mark({"paths": ["repo-patrol/2026-10-07-2.md"]})
        self.assertEqual(data["marked"], 0)
        self.assertEqual(len(self.read_records()), 1)
        _, text, _ = self.request("GET", "/reports")
        self.assertNotIn('data-path="repo-patrol/2026-10-07-2.md"', text)
        _, text, _ = self.request("GET", "/reports?view=all")
        self.assertIn('data-path="repo-patrol/2026-10-07-2.md" data-read="1"', text)
        # フォームの送信（JavaScript なし）
        status, _, r = self.request("POST", "/api/reports/read",
                                    {"token": self.token(), "path": "memory-audit/2026-10-06.md"})
        self.assertEqual(status, 303)
        self.assertEqual(r.getheader("Location"), "/reports?view=unread&read=memory-audit/2026-10-06.md")
        _, text, _ = self.request("GET", r.getheader("Location"))
        self.assertIn("memory-audit 2026-10-06.md を既読にしました。", text)
        # すべて
        status, data, _ = self.mark({"all": True})
        self.assertEqual(data, {"marked": 3, "counts": {"unread": 0, "all": 5}})
        recs = self.read_records()
        self.assertEqual(len(recs), 5)
        self.assertEqual(len(set(recs)), 5)
        self.assertTrue(all(x.startswith(root + "/") for x in recs))
        _, text, _ = self.request("GET", "/reports")
        self.assertIn("未読のレポートはありません。", text)
        self.assertNotIn("未読をすべて既読にする", text)
        self.assertIn('レポート（未読 <span class="unread-count">0</span> 件）', text)

    def test_18_reports_mark_read_rejected(self):
        write(os.path.join(self.work, "reports", "feedback-mining", "2026-10-10.md"), "x")
        before = self.read_records()
        bad =["../outside.md", "repo-patrol/../../outside.md", "/etc/passwd", "repo-patrol/2026-10-08.md",
               "repo-patrol/notes.md", "proposals/2026-10-09.md", ".hidden/2026-10-09.md",
               "memory-audit/.snapshots/2026-10-09.md", "repo-patrol/2026-10-01.md", "repo-patrol", ""]
        for k in bad:
            status, _, _ = self.mark({"paths": ["feedback-mining/2026-10-10.md", k]})
            self.assertEqual(status, 400, k)
        for payload in ({}, {"paths": []}, {"paths": "repo-patrol/2026-10-05.md"}, {"paths": [1]}, {"all": "yes"}):
            status, _, _ = self.mark(payload)
            self.assertEqual(status, 400, payload)
        # 合言葉と Origin
        status, _, _ = self.mark({"all": True}, token="")
        self.assertEqual(status, 403)
        status, _, _ = self.mark({"all": True}, token="wrong")
        self.assertEqual(status, 403)
        status, _, _ = self.mark({"all": True}, origin=None)
        self.assertEqual(status, 403)
        status, _, _ = self.mark({"all": True}, origin="http://evil.example")
        self.assertEqual(status, 403)
        status, _, _ = self.request("POST", "/api/reports/read", {"all": "1"})
        self.assertEqual(status, 403)
        status, _, _ = self.request("POST", "/api/reports/read", {"token": self.token(), "path": "../outside.md"})
        self.assertEqual(status, 400)
        self.assertEqual(self.read_records(), before)

    # ---- スキル ----
    def make_skills(self):
        """スキルの置き場所を作る。2回目以降は作り直さない。"""
        sk = self.skills
        if os.path.isdir(sk):
            return sk
        os.makedirs(os.path.join(sk, "beta", "references", "deep", "deeper"))
        os.makedirs(os.path.join(sk, "beta", "history"))
        os.makedirs(os.path.join(sk, "beta", ".snap"))
        os.makedirs(os.path.join(sk, "beta", "node_modules", "pkg"))
        write(os.path.join(sk, "beta", "SKILL.md"),
              '---\nname: beta\ndescription: "%s"\nallowed-tools:\n  - Read\n---\n\n# ベータ\n\n'
              '<script>alert(1)</script>\n\n[参照](references/guide.md) [外](../alpha/SKILL.md) '
              '[危険](javascript:alert(1)) [無い](nothing.md)\n\n| 列 | 説明 |\n|---|---|\n| a | **b** |\n'
              % ("ベータの説明。" + "あ" * 250))
        write(os.path.join(sk, "beta", "references", "guide.md"), "# 手引き\n\n[戻る](../SKILL.md#top)\n")
        write(os.path.join(sk, "beta", "references", "deep", "level3.md"), "# 3段目\n")
        write(os.path.join(sk, "beta", "references", "deep", "deeper", "level4.md"), "# 4段目\n")
        write(os.path.join(sk, "beta", "history", "old.md"), "# 古い\n")
        write(os.path.join(sk, "beta", ".snap", "x.md"), "# 隠し\n")
        write(os.path.join(sk, "beta", "node_modules", "pkg", "README.md"), "# 依存\n")
        write(os.path.join(sk, "beta", "notes.txt"), "テキスト\n")
        write(os.path.join(self.work, "secret-outside.md"), "外の秘密\n")
        os.symlink(os.path.join(self.work, "secret-outside.md"), os.path.join(sk, "beta", "escape.md"))
        os.makedirs(os.path.join(sk, "alpha"))
        write(os.path.join(sk, "alpha", "SKILL.md"), "---\nname: alpha\ndescription: アルファの説明\n---\n本文\n")
        # 相対パスのリンク（2つ目の設定ディレクトリの skills と同じ形）
        ext = os.path.join(self.work, "agents", "linked")
        os.makedirs(ext)
        write(os.path.join(ext, "SKILL.md"), "---\nname: linked\ndescription: リンクの先のスキル\n---\n# リンク\n")
        os.symlink(os.path.relpath(ext, sk), os.path.join(sk, "linked"))
        # 数えないもの
        for name in ("synced", ".hidden", "excluded-by-env"):
            os.makedirs(os.path.join(sk, name))
            write(os.path.join(sk, name, "SKILL.md"), "---\nname: %s\n---\n" % name)
        os.makedirs(os.path.join(sk, "no-skill-md"))
        write(os.path.join(sk, "no-skill-md", "README.md"), "x")
        write(os.path.join(sk, "top-level.md"), "x")
        os.symlink(os.path.join(self.work, "nowhere"), os.path.join(sk, "broken"))
        return sk

    def test_19_skills_toggle(self):
        # スキルがまだ無い（置き場所が無い）ときは、スキルの項目を出さない
        _, text, _ = self.request("GET", "/")
        self.assertNotIn('href="/skills"', text)
        self.make_skills()
        _, text, _ = self.request("GET", "/")
        self.assertIn('<nav class="switch" aria-label="表示の切り替え"><a href="/" aria-current="page">承認待ち</a>'
                      '<a href="/reports">レポート（未読 <span class="unread-count">', text)
        self.assertIn('<a href="/skills">スキル（3 件）</a></nav>', text)
        _, text, _ = self.request("GET", "/reports")
        self.assertIn('<a href="/skills">スキル（3 件）</a>', text)
        _, text, _ = self.request("GET", "/skills")
        self.assertIn('<a href="/skills" aria-current="page">スキル（3 件）</a>', text)
        # レポートのジョブが無いときは「承認待ち」と「スキル」だけ
        root = os.path.join(self.work, "reports")
        moved = root + ".moved"
        os.rename(root, moved)
        try:
            _, text, _ = self.request("GET", "/")
            self.assertIn('<nav class="switch" aria-label="表示の切り替え"><a href="/" aria-current="page">承認待ち</a>'
                          '<a href="/skills">スキル（3 件）</a></nav>', text)
            # スキルも無ければトグルを出さない
            os.rename(self.skills, self.skills + ".moved")
            try:
                _, text, _ = self.request("GET", "/")
                self.assertNotIn('nav class="switch"', text)
                status, text, _ = self.request("GET", "/skills")
                self.assertEqual(status, 200)
                self.assertIn("スキルはありません。置き場所（~/skills）にスキルのフォルダを置くと、ここに表示されます。", text)
            finally:
                os.rename(self.skills + ".moved", self.skills)
        finally:
            os.rename(moved, root)

    def test_20_skills_list(self):
        self.make_skills()
        status, text, r = self.request("GET", "/skills")
        self.assertEqual(status, 200)
        names = [x.split('"')[0] for x in text.split('<h2><a href="/skills/')[1:]]
        self.assertEqual(names, ["alpha", "beta", "linked"])
        self.assertIn("アルファの説明", text)
        # カードに出す説明は先頭 200 文字まで。絞り込みの対象（data-search）には全文を入れる
        self.assertIn('<p class="text">ベータの説明。' + "あ" * 193 + "…</p>", text)
        self.assertIn('data-search="beta ベータの説明。' + "あ" * 250 + '"', text)
        self.assertIn('<dt>リンクの先</dt><dd class="path">~/agents/linked</dd>', text)
        self.assertIn('<script src="/static/skills.js" defer></script>', text)
        self.assertIn('id="skill-q"', text)
        self.assertIn('data-search="alpha アルファの説明"', text)
        self.assertIsNotNone(r.getheader("Content-Security-Policy"))
        status, js, _ = self.request("GET", "/static/skills.js")
        self.assertEqual(status, 200)
        self.assertIn("skill-q", js)

    def test_21_skill_detail(self):
        self.make_skills()
        status, text, _ = self.request("GET", "/skills/beta")
        self.assertEqual(status, 200)
        # 前付けは表、本文は整形する
        self.assertIn("<tr><th>name</th><td>beta</td></tr>", text)
        self.assertIn("<tr><th>allowed-tools</th><td>- Read</td></tr>", text)
        self.assertIn("<h1>ベータ</h1>", text)
        self.assertNotIn("<script>alert", text)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", text)
        self.assertIn('<div class="md-table"><table>', text)
        self.assertIn("<strong>b</strong>", text)
        # 同じスキルの中の .md へのリンクは書き換え、それ以外は文字のまま
        self.assertIn('<a href="/skills/beta/references/guide.md">参照</a>', text)
        self.assertIn("[外](../alpha/SKILL.md)", text)
        self.assertIn("[危険](javascript:alert(1))", text)
        self.assertIn("[無い](nothing.md)", text)
        # ほかの .md の一覧。今開いているものに印を付ける。対象外の場所と深さ 4 は出さない
        self.assertIn('<a href="/skills/beta/SKILL.md" aria-current="page">SKILL.md</a>（表示中）', text)
        self.assertIn('<a href="/skills/beta/references/guide.md">references/guide.md</a>', text)
        self.assertIn('<a href="/skills/beta/references/deep/level3.md">', text)
        for hidden in ("level4.md", "history/old.md", ".snap/x.md", "node_modules", "escape.md", "notes.txt"):
            self.assertNotIn(hidden, text, hidden)
        # 編集・削除の手段は無い
        self.assertNotIn("<form", text)
        self.assertNotIn("<button", text)

        status, text, _ = self.request("GET", "/skills/beta/references/guide.md")
        self.assertEqual(status, 200)
        self.assertIn("<h1>手引き</h1>", text)
        self.assertIn('<a href="/skills/beta/SKILL.md#top">戻る</a>', text)
        self.assertIn('<a href="/skills/beta/references/guide.md" aria-current="page">', text)
        status, text, _ = self.request("GET", "/skills/linked")
        self.assertEqual(status, 200)
        self.assertIn("<h1>リンク</h1>", text)
        self.assertIn("~/agents/linked", text)

    def test_22_skill_not_found(self):
        self.make_skills()
        bad = ["/skills/nosuch", "/skills/synced", "/skills/.hidden", "/skills/excluded-by-env", "/skills/no-skill-md",
               "/skills/broken", "/skills/top-level.md", "/skills/..", "/skills/beta/../alpha/SKILL.md",
               "/skills/beta/%2e%2e/alpha/SKILL.md", "/skills/beta//etc/passwd", "/skills/beta/escape.md",
               "/skills/beta/notes.txt", "/skills/beta/history/old.md", "/skills/beta/.snap/x.md",
               "/skills/beta/node_modules/pkg/README.md", "/skills/beta/references/deep/deeper/level4.md",
               "/skills/beta/references", "/skills/beta/nothing.md"]
        for path in bad:
            status, text, _ = self.request("GET", path)
            self.assertEqual(status, 404, path)
            self.assertNotIn("外の秘密", text)
        self.assertIn("指定されたスキルまたはファイルはありません。スキルの一覧から選び直してください。", text)
        self.assertNotIn("macOS の制限", text)

    def test_23_skill_post_rejected(self):
        self.make_skills()
        for path in ("/skills", "/skills/beta", "/skills/beta/SKILL.md"):
            status, _, r = self.request("POST", path, {"token": self.token(), "body": "x"})
            self.assertEqual(status, 405, path)
            self.assertEqual(r.getheader("Allow"), "GET, HEAD")
        self.assertIn("# ベータ", read(os.path.join(self.skills, "beta", "SKILL.md")))

    def test_24_skill_restricted(self):
        # launchd から起動したサーバーが書類の中を開けない状態を、権限を外して再現する。
        # ディレクトリは x だけ残し、SKILL.md の有無は確かめられるが一覧と読み込みはできない形にする。
        self.make_skills()
        locked = os.path.join(self.skills, "locked")
        os.makedirs(locked)
        write(os.path.join(locked, "SKILL.md"), "---\nname: locked\ndescription: 読めない説明\n---\n# 本文\n")
        os.chmod(os.path.join(locked, "SKILL.md"), 0)
        os.chmod(locked, 0o111)
        try:
            status, text, _ = self.request("GET", "/skills")
            self.assertEqual(status, 200)
            self.assertIn('<h2><a href="/skills/locked">locked</a></h2>', text)
            self.assertIn("macOS の制限で説明を読み込めません。", text)
            self.assertNotIn("読めない説明", text)
            for path in ("/skills/locked", "/skills/locked/SKILL.md"):
                status, text, _ = self.request("GET", path)
                self.assertEqual(status, 200, path)
                self.assertIn("<h1>locked</h1>", text)
                self.assertIn("このスキルは macOS の制限で読み込めません。書類・デスクトップ・ダウンロードのフォルダの中にある"
                              "ファイルは、この画面からは開けません。", text)
                self.assertIn('実体の場所: <span class="path">~/skills/locked</span>', text)
                self.assertIn("中身はファイルを直接開いて確認してください。", text)
                self.assertNotIn("# 本文", text)
            # パスの形が不正なものは、読めないスキルでも 404 のまま
            for path in ("/skills/locked/../beta/SKILL.md", "/skills/locked/notes.txt"):
                status, _, _ = self.request("GET", path)
                self.assertEqual(status, 404, path)
        finally:
            os.chmod(locked, 0o755)
            os.chmod(os.path.join(locked, "SKILL.md"), 0o644)
            shutil.rmtree(locked)


class NotifierTest(unittest.TestCase):
    """Notifier の切り替えとログ。terminal-notifier と osascript は偽のコマンドに差し替える。"""

    def setUp(self):
        sys.path.insert(0, os.path.dirname(SERVER))
        import inbox_server
        self.mod = inbox_server
        self.work = tempfile.mkdtemp(prefix="review-notifier-test.")
        self.bin = os.path.join(self.work, "bin")
        os.makedirs(self.bin)
        self.calls = os.path.join(self.work, "calls.log")
        self.osa = os.path.join(self.work, "osascript")
        self.fake(self.osa, 'printf "osascript\\n" >>"%s"\nexit "${FAKE_OSA_RC:-0}"\n' % self.calls)
        self.env = dict(os.environ)
        os.environ.pop("CLAUDE_REVIEW_NOTIFY_CMD", None)
        os.environ["PATH"] = self.bin + ":/usr/bin:/bin"
        os.environ["CLAUDE_REVIEW_OSASCRIPT"] = self.osa
        self.logs = []
        self.orig_log = inbox_server.log
        inbox_server.log = self.logs.append
        self.state = os.path.join(self.work, "state")
        os.environ["CLAUDE_REVIEW_STATE"] = self.state

    def tearDown(self):
        self.mod.log = self.orig_log
        os.environ.clear()
        os.environ.update(self.env)
        shutil.rmtree(self.work, ignore_errors=True)

    def fake(self, path, body):
        write(path, "#!/bin/bash\n" + body)
        os.chmod(path, 0o755)

    def fake_tn(self, rc, err=""):
        self.fake(os.path.join(self.bin, "terminal-notifier"),
                  'printf "terminal-notifier\\n" >>"%s"\nprintf "%%s\\n" "%s" >&2\nexit %d\n' % (self.calls, err, rc))

    def called(self):
        return read(self.calls).split() if os.path.exists(self.calls) else []

    def test_terminal_notifier_success(self):
        self.fake_tn(0)
        name, reasons = self.mod.Notifier("http://x").send("t", "m", "http://x/")
        self.assertEqual(name, "terminal-notifier")
        self.assertEqual(self.called(), ["terminal-notifier"])

    def test_terminal_notifier_failure_falls_back(self):
        self.fake_tn(3, "Notifications are not allowed for this application")
        name, reasons = self.mod.Notifier("http://x").send("t", "m", "http://x/")
        self.assertEqual(name, "osascript")
        self.assertEqual(self.called(), ["terminal-notifier", "osascript"])
        self.assertEqual(len(self.logs), 1)
        self.assertIn("terminal-notifier で通知を出せませんでした", self.logs[0])
        self.assertIn("終了コード 3", self.logs[0])
        self.assertIn("Notifications are not allowed", self.logs[0])

    def watcher(self):
        pdir = os.path.join(self.work, "proposals")
        os.makedirs(pdir, exist_ok=True)
        w = self.mod.Watcher(pdir, self.mod.Notifier("http://x"), 1)
        if self.mod.pl.state_dir() != self.state:
            self.skipTest("状態の置き場所を差し替えられません")
        w.scan_once()  # 初回は記録を作るだけ
        write(os.path.join(pdir, "2026-10-05-01-a.md"), PROPOSAL.format(id="2026-10-05-01", status="pending"))
        return w

    def test_watcher_logs_method(self):
        self.fake_tn(3, "Notifications are not allowed for this application")
        w = self.watcher()
        w.scan_once()
        self.assertTrue(any(x.startswith("通知しました（osascript）: 2026-10-05-01") for x in self.logs), self.logs)

    def test_watcher_logs_failure_and_records(self):
        self.fake_tn(3, "Notifications are not allowed for this application")
        os.environ["FAKE_OSA_RC"] = "1"
        w = self.watcher()
        w.scan_once()
        self.assertFalse(any(x.startswith("通知しました") for x in self.logs), self.logs)
        err = [x for x in self.logs if x.startswith("ERROR: 通知に失敗しました")]
        self.assertEqual(len(err), 1, self.logs)
        self.assertIn("2026-10-05-01", err[0])
        self.assertIn("Notifications are not allowed", err[0])
        self.assertIn("osascript: 終了コード 1", err[0])
        # 失敗した案も通知済みとして記録し、次の走査で出し直さない。
        n = len(self.called())
        self.assertEqual(w.scan_once(), [])
        self.assertEqual(len(self.called()), n)


if __name__ == "__main__":
    unittest.main(verbosity=2)
