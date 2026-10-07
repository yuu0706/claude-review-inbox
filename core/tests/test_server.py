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
        })
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
        conn.putrequest("POST", path, skip_host=True)
        for k, v in headers.items():
            conn.putheader(k, v)
        conn.endheaders(data)
        r = conn.getresponse()
        text = r.read().decode("utf-8")
        conn.close()
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
        for label in ("承認する", "保留にする", "却下する"):
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
