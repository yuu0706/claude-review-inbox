#!/usr/bin/python3
"""承認待ちの変更を確かめる画面と、承認待ちが増えたときの通知を受け持つ小さな HTTP サーバー。

Python 3.9 の標準ライブラリだけで動く。127.0.0.1 だけで待ち受ける。

環境変数:
  CLAUDE_REVIEW_PORT           待ち受けるポート（既定 8010）
  CLAUDE_REVIEW_PROPOSALS      案の置き場所（既定 ${CLAUDE_REPORTS_ROOT:-~/claude-reports}/proposals）
  CLAUDE_REVIEW_STATE          台帳と通知済みの記録の置き場所（既定 ~/.local/state/claude-review-inbox）
  CLAUDE_REVIEW_SCAN_INTERVAL  置き場所を走査する間隔の秒数（既定 10）
  CLAUDE_REVIEW_NOTIFY_CMD     通知のコマンドを差し替える（検査用）。<タイトル> <本文> <URL> を引数に渡す
  CLAUDE_REVIEW_OSASCRIPT      terminal-notifier が使えないときに使う osascript の場所（検査用。既定 /usr/bin/osascript）
"""

import datetime
import html
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "skills", "change-review", "scripts"))
import proposal_lib as pl  # noqa: E402

HOST = "127.0.0.1"
STATUS_ORDER = ("pending", "approved", "hold", "rejected", "applied")
STATUS_LABEL = {
    "pending": "承認待ち",
    "approved": "承認済み",
    "hold": "保留",
    "rejected": "却下",
    "applied": "反映済み",
}
# ボタンの文言。押した結果の状態ごとに持つ。
BUTTON_LABEL = {
    "approved": "承認する",
    "hold": "保留にする",
    "rejected": "却下する",
    "pending": "承認待ちに戻す",
}
DONE_MESSAGE = {
    "approved": "承認しました。反映は会話で「承認分を反映して」と伝えると行われます。",
    "hold": "保留にしました。",
    "rejected": "却下しました。否認リストに記録しました。",
    "pending": "承認待ちに戻しました。",
}
DECIDE_LOCK = threading.Lock()


def empty_message(status):
    if status == "pending":
        return "承認待ちの変更はありません。定期実行や会話で案が作られると、ここに表示されます。"
    return "%sの変更はありません。" % STATUS_LABEL[status]


def log(msg):
    sys.stdout.write("[%s] %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stdout.flush()


def esc(v):
    return html.escape(str(v), quote=True)


CSS = """
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0;
  --card: #f6f8fa; --accent: #0969da; --add-bg: #dafbe1; --add-fg: #116329; --del-bg: #ffebe9; --del-fg: #a40e26;
  --ok: #1a7f37; --warn: #9a6700; --ng: #cf222e; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --line: #3d444d; --card: #151b23; --accent: #4493f8;
    --add-bg: #12261e; --add-fg: #7ee787; --del-bg: #25171c; --del-fg: #ffa198; --ok: #3fb950; --warn: #d29922; --ng: #f85149; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif;
  font-size: 15px; line-height: 1.6; }
main { max-width: 1100px; margin: 0 auto; padding: 16px 20px 48px; }
h1 { font-size: 1.4rem; margin: 8px 0 16px; }
h2 { font-size: 1.15rem; margin: 24px 0 8px; border-bottom: 1px solid var(--line); padding-bottom: 4px; }
h3 { font-size: 1rem; margin: 16px 0 8px; }
a { color: var(--accent); }
nav.tabs { display: flex; flex-wrap: wrap; gap: 4px; border-bottom: 1px solid var(--line); margin-bottom: 12px; }
nav.tabs a { padding: 6px 12px; text-decoration: none; color: var(--fg); border: 1px solid transparent;
  border-bottom: none; border-radius: 6px 6px 0 0; }
nav.tabs a[aria-current="page"] { border-color: var(--line); background: var(--card); font-weight: bold; }
table { border-collapse: collapse; width: 100%; }
th, td { border-bottom: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
th { color: var(--muted); font-weight: normal; font-size: 0.9rem; }
td.num { white-space: nowrap; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
td.path, .path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85rem; word-break: break-all; }
.empty { color: var(--muted); padding: 16px 0; }
.meta { background: var(--card); border: 1px solid var(--line); border-radius: 6px; padding: 8px 12px; }
.meta dt { color: var(--muted); font-size: 0.85rem; }
.meta dd { margin: 0 0 6px; }
.status { display: inline-block; padding: 0 8px; border: 1px solid var(--line); border-radius: 10px; font-size: 0.85rem; }
.message { border: 1px solid var(--ok); color: var(--ok); border-radius: 6px; padding: 8px 12px; margin: 8px 0; }
pre { background: var(--card); border: 1px solid var(--line); border-radius: 6px; padding: 8px; overflow-x: auto;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85rem; line-height: 1.45; }
pre.diff { padding: 0; }
pre.diff span { display: block; padding: 0 8px; white-space: pre; }
pre.diff .add { background: var(--add-bg); color: var(--add-fg); }
pre.diff .del { background: var(--del-bg); color: var(--del-fg); }
pre.diff .hunk { color: var(--accent); }
pre.diff .file { color: var(--muted); font-weight: bold; }
.text { white-space: pre-wrap; word-break: break-word; }
form.decide { margin-top: 16px; background: var(--card); border: 1px solid var(--line); border-radius: 6px; padding: 12px; }
form.decide label { display: block; font-weight: bold; margin-bottom: 4px; }
form.decide .help { color: var(--muted); font-size: 0.85rem; margin: 0 0 6px; }
form.decide textarea { width: 100%; min-height: 4.5em; font: inherit; color: var(--fg); background: var(--bg);
  border: 1px solid var(--line); border-radius: 6px; padding: 6px; }
.buttons { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
button { font: inherit; padding: 6px 14px; border-radius: 6px; border: 1px solid var(--line); background: var(--bg);
  color: var(--fg); cursor: pointer; }
button.approved { border-color: var(--ok); color: var(--ok); }
button.hold { border-color: var(--warn); color: var(--warn); }
button.rejected { border-color: var(--ng); color: var(--ng); }
.readonly { color: var(--muted); }
:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
.cards { display: flex; flex-direction: column; gap: 16px; }
.card { background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 12px 16px; min-width: 0; }
.card.highlight, .card:target { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent); }
.card-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; }
.card-head h2 { flex: 1 1 16em; min-width: 0; margin: 0; border: none; padding: 0; font-size: 1.05rem; word-break: break-word; }
.card-head .num { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); font-size: 0.9rem; }
.card dl.facts { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 2px 12px; margin: 8px 0; }
.card dl.facts dt { color: var(--muted); font-size: 0.85rem; }
.card dl.facts dd { margin: 0; min-width: 0; word-break: break-word; }
.card h3 { font-size: 0.95rem; margin: 12px 0 4px; }
.card details { margin: 8px 0; }
.card summary { cursor: pointer; color: var(--accent); }
.card .error { border: 1px solid var(--ng); color: var(--ng); border-radius: 6px; padding: 6px 10px; margin: 8px 0; }
.card .detail-link { margin: 8px 0 0; font-size: 0.85rem; }
.toast { position: fixed; left: 50%; bottom: 16px; transform: translateX(-50%); max-width: calc(100% - 24px);
  display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; background: var(--fg); color: var(--bg);
  border-radius: 8px; padding: 8px 12px; box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3); }
.toast[hidden] { display: none; }
.offline { position: sticky; top: 0; z-index: 1; border: 1px solid var(--ng); color: var(--ng); background: var(--bg);
  border-radius: 6px; padding: 8px 12px; margin: 0 0 12px; }
.offline[hidden] { display: none; }
.card.new { border-color: var(--ok); box-shadow: 0 0 0 2px var(--ok); }
.card .new-label { display: inline-block; padding: 0 8px; border: 1px solid var(--ok); border-radius: 10px;
  color: var(--ok); font-size: 0.85rem; }
.toast button { background: transparent; color: var(--bg); border-color: var(--bg); padding: 2px 10px; }
@media (max-width: 480px) { main { padding: 12px 10px 64px; } .card { padding: 10px; } }
"""


def page(title, body, script=False):
    tag = '<script src="/static/app.js" defer></script>\n' if script else ""
    return (
        "<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        "<title>%s | 承認待ちの変更</title>\n<style>%s</style>\n%s</head>\n<body>\n<main>\n%s\n</main>\n</body>\n</html>\n"
        % (esc(title), CSS, tag, body)
    )


def diff_kind(line):
    """差分の1行の種類を返す。header（ファイル名・範囲）・add・del・context のいずれか。"""
    if line.startswith("+++ ") or line.startswith("--- ") or line.startswith("@@"):
        return "header"
    if line.startswith("+"):
        return "add"
    if line.startswith("-"):
        return "del"
    return "context"


FENCE_RE = re.compile(r"^(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)\s*$")


def parse_sections(body):
    """本文を「## 」の節に分け、理由・差分の行・それ以外の節を返す。

    差分は diff のコードブロックをすべて集め、行ごとに {"kind", "text"} にする。
    それ以外の節は {"title", "text"} とし、diff のコードブロックを除いた文を元のまま入れる。
    """
    sections = []
    cur = {"title": "", "lines": []}
    fence = None
    for line in body.splitlines():
        if fence is None:
            m = FENCE_RE.match(line)
            if m:
                fence = re.compile(r"^%s{%d,}\s*$" % (re.escape(m.group(1)[0]), len(m.group(1))))
            elif re.match(r"^##\s+", line):
                sections.append(cur)
                cur = {"title": re.sub(r"^##\s+", "", line).strip(), "lines": []}
                continue
        elif fence.match(line):
            fence = None
        cur["lines"].append(line)
    sections.append(cur)

    reason = ""
    diff = []
    others = []
    for sec in sections:
        text_lines = []
        lines = sec["lines"]
        i = 0
        while i < len(lines):
            m = FENCE_RE.match(lines[i])
            if m and m.group(2).lower() == "diff":
                closing = re.compile(r"^%s{%d,}\s*$" % (re.escape(m.group(1)[0]), len(m.group(1))))
                i += 1
                while i < len(lines) and not closing.match(lines[i]):
                    diff.append({"kind": diff_kind(lines[i]), "text": lines[i]})
                    i += 1
                i += 1
                continue
            if not (sec["title"] == "" and lines[i].startswith("# ")):
                text_lines.append(lines[i])
            i += 1
        text = "\n".join(text_lines).strip("\n")
        if sec["title"] == "理由" and not reason:
            reason = text
        elif text.strip():
            others.append({"title": sec["title"], "text": text})
    return reason, diff, others


def proposal_item(p):
    """一覧と判断の API が返す案の1件分。"""
    reason, diff, others = parse_sections(p.body)
    meta = p.meta
    return {
        "id": p.id, "name": p.name, "slug": p.name[:-3], "number": p.number, "status": p.status,
        "heading": p.heading, "targets": meta.get("targets") or [], "created": meta.get("created", ""),
        "source": meta.get("source", ""), "decided": meta.get("decided", ""), "note": meta.get("note", ""),
        "reason": reason, "diff": diff, "sections": others,
    }


def render_diff(lines):
    out = []
    for i, line in enumerate(lines):
        cls = ""
        if line.startswith("+++ ") or line.startswith("--- "):
            cls = "file"
        elif line.startswith("@@"):
            cls = "hunk"
        elif line.startswith("+"):
            cls = "add"
        elif line.startswith("-"):
            cls = "del"
        out.append('<span class="%s">%s</span>' % (cls, esc(line) if line else " "))
    return '<pre class="diff">%s</pre>' % "".join(out)


def render_body(body):
    """本文を表示用の HTML にする。見出しとコードブロックだけを解釈し、それ以外はエスケープした文として出す。"""
    out = []
    para = []

    def flush_para():
        if para:
            text = "\n".join(para).strip("\n")
            if text.strip():
                out.append('<div class="text">%s</div>' % esc(text))
            del para[:]

    lines = body.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)\s*$", line)
        if m:
            flush_para()
            fence, lang = m.group(1), m.group(2).lower()
            block = []
            i += 1
            closing = re.compile(r"^%s{%d,}\s*$" % (re.escape(fence[0]), len(fence)))
            while i < len(lines) and not closing.match(lines[i]):
                block.append(lines[i])
                i += 1
            i += 1
            if lang == "diff":
                out.append(render_diff(block))
            else:
                out.append("<pre>%s</pre>" % esc("\n".join(block)))
            continue
        h = re.match(r"^(#{1,6})\s+(.*)$", line)
        if h:
            flush_para()
            level = min(len(h.group(1)) + 1, 6)
            out.append("<h%d>%s</h%d>" % (level, esc(h.group(2).strip()), level))
        else:
            para.append(line)
        i += 1
    flush_para()
    return "\n".join(out)


class Notifier(object):
    """通知を出す。terminal-notifier が失敗したら osascript で出し直す。"""

    def __init__(self, base_url):
        self.base_url = base_url

    @staticmethod
    def _run(cmd):
        """コマンドを実行し、失敗の理由を返す。成功なら None を返す。"""
        try:
            r = subprocess.run(cmd, timeout=30, check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except (OSError, subprocess.SubprocessError) as e:
            return str(e)
        if r.returncode != 0:
            err = r.stderr.decode("utf-8", "replace").strip()
            return "終了コード %d: %s" % (r.returncode, err or "（標準エラーの出力なし）")
        return None

    def send(self, title, message, url):
        """通知を出し、(成功した手段の名前, 失敗の理由の一覧) を返す。すべて失敗したら名前は None。"""
        attempts = []
        custom = os.environ.get("CLAUDE_REVIEW_NOTIFY_CMD")
        if custom:
            attempts.append(("CLAUDE_REVIEW_NOTIFY_CMD", [custom, title, message, url]))
        else:
            path = os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin"
            tn = shutil.which("terminal-notifier", path=path)
            if tn:
                attempts.append(("terminal-notifier", [tn, "-title", title, "-message", message, "-open", url,
                                                       "-group", "claude-review-inbox"]))
            script = 'display notification "%s" with title "%s"' % (
                message.replace("\\", "\\\\").replace('"', '\\"'),
                title.replace("\\", "\\\\").replace('"', '\\"'))
            osascript = os.environ.get("CLAUDE_REVIEW_OSASCRIPT", "/usr/bin/osascript")
            attempts.append(("osascript", [osascript, "-e", script]))
        reasons = []
        for name, cmd in attempts:
            reason = self._run(cmd)
            if reason is None:
                return name, reasons
            log("WARN: %s で通知を出せませんでした（%s）" % (name, reason))
            reasons.append("%s: %s" % (name, reason))
        return None, reasons


class Watcher(threading.Thread):
    """置き場所を一定の間隔で走査し、新しい pending があれば通知する。"""

    def __init__(self, directory, notifier, interval):
        threading.Thread.__init__(self, daemon=True)
        self.directory = directory
        self.notifier = notifier
        self.interval = interval
        self.stop_event = threading.Event()

    @property
    def record(self):
        return os.path.join(pl.state_dir(), "notified.json")

    def load(self):
        try:
            with open(self.record, "r", encoding="utf-8") as f:
                data = json.load(f)
            return set(x for x in data.get("notified", []) if isinstance(x, str))
        except (OSError, ValueError, AttributeError):
            return None

    def save(self, ids):
        os.makedirs(pl.state_dir(), exist_ok=True)
        tmp = self.record + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"notified": sorted(ids)}, f, ensure_ascii=False, indent=1)
        os.replace(tmp, self.record)

    def scan_once(self):
        pending = [p for p in pl.list_proposals(self.directory) if p.status == "pending"]
        known = self.load()
        if known is None:
            # 初めて起動したときは、既存の承認待ちを通知済みとして記録するだけで通知しない。
            self.save(set(p.id for p in pending))
            log("通知済みの記録を作りました（既存の承認待ち %d件は通知しません）" % len(pending))
            return []
        new = [p for p in pending if p.id not in known]
        if not new:
            return []
        if len(new) == 1:
            p = new[0]
            url = "%s/?status=pending#%s" % (self.notifier.base_url, urllib.parse.quote(p.id))
            method, reasons = self.notifier.send("承認待ちが届きました", p.heading or p.id, url)
        else:
            method, reasons = self.notifier.send("承認待ちが届きました", "承認待ちが%d件届きました" % len(new),
                                        self.notifier.base_url + "/")
        # 失敗した案も通知済みとして記録し、同じ案で失敗を繰り返さない。
        self.save(known | set(p.id for p in new))
        ids = ", ".join(p.id for p in new)
        if method:
            log("通知しました（%s）: %s" % (method, ids))
        else:
            log("ERROR: 通知に失敗しました: %s（理由: %s）" % (ids, " / ".join(reasons) or "通知の手段がありません"))
        return new

    def run(self):
        while not self.stop_event.is_set():
            try:
                self.scan_once()
            except Exception as e:  # 見張りは止めない
                log("ERROR: 走査に失敗しました: %s" % e)
            self.stop_event.wait(self.interval)


class Handler(BaseHTTPRequestHandler):
    server_version = "claude-review-inbox"
    sys_version = ""

    # ---- 共通 ----
    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))

    @property
    def directory(self):
        return self.server.proposals_dir

    def allowed_origins(self):
        port = self.server.server_address[1]
        return ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)

    def host_ok(self):
        port = self.server.server_address[1]
        host = (self.headers.get("Host") or "").strip().lower()
        return host in ("127.0.0.1:%d" % port, "localhost:%d" % port)

    def origin_ok(self):
        origin = self.headers.get("Origin")
        allowed = self.allowed_origins()
        if origin is not None:
            return origin.strip() in allowed
        referer = self.headers.get("Referer")
        if referer:
            return any(referer == o or referer.startswith(o + "/") for o in allowed)
        return False

    def send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; "
                         "form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def error_page(self, code, title, message):
        body = '<h1>%s</h1>\n<p>%s</p>\n<p><a href="/">承認待ちの一覧へ戻る</a></p>' % (esc(title), esc(message))
        self.send(code, page(title, body))

    def forbidden(self):
        self.send(403, page("受け付けられません",
                            "<h1>受け付けられません</h1>\n<p>この画面は、この Mac のブラウザで "
                            "http://127.0.0.1:%d/ を開いたときだけ使えます。</p>" % self.server.server_address[1]))

    # ---- GET ----
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.host_ok():
            return self.forbidden()
        u = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(u.path)
        q = urllib.parse.parse_qs(u.query)
        if path == "/":
            return self.list_page((q.get("status") or ["pending"])[0])
        if path == "/api/proposals":
            return self.api_list()
        if path.startswith("/static/"):
            return self.static_file(path[len("/static/"):])
        if path.startswith("/p/"):
            return self.detail_page(path[3:], (q.get("done") or [""])[0])
        return self.error_page(404, "ページが見つかりません", "指定されたページはありません。")

    def api_list(self):
        items = [proposal_item(p) for p in pl.list_proposals(self.directory)]
        self.send(200, json.dumps(items, ensure_ascii=False), "application/json; charset=utf-8")

    def static_file(self, name):
        if name != "app.js":
            return self.error_page(404, "ページが見つかりません", "指定されたページはありません。")
        with open(os.path.join(HERE, "static", name), "r", encoding="utf-8") as f:
            self.send(200, f.read(), "text/javascript; charset=utf-8")

    def render_card(self, p, status):
        """一覧のカード1件。JavaScript が動かないときも、フォームの POST で判断できる。

        static/app.js の buildCard と同じ構造にする。
        """
        item = proposal_item(p)
        slug = urllib.parse.quote(item["slug"])
        facts = [
            ("対象", '<span class="path">%s</span>' % ("<br>".join(esc(t) for t in item["targets"]) or "なし")),
            ("作成日時", esc(item["created"])),
            ("出した元", esc(item["source"])),
        ]
        if item["decided"]:
            facts.append(("判断した日時", esc(item["decided"])))
        if item["note"] and p.status == "applied":
            facts.append(("メモ", '<span class="text">%s</span>' % esc(item["note"])))
        out = [
            '<article class="card" id="%s" data-slug="%s" data-status="%s">' % (esc(item["id"]), esc(item["slug"]), esc(p.status)),
            '<div class="card-head"><span class="num">%s</span><h2>%s</h2><span class="status">%s</span></div>'
            % (esc(item["number"]), esc(item["heading"] or "（見出しなし）"), esc(STATUS_LABEL.get(p.status, p.status))),
            '<dl class="facts">%s</dl>' % "".join("<dt>%s</dt><dd>%s</dd>" % f for f in facts),
        ]
        if item["reason"]:
            out.append('<h3>理由</h3><div class="text">%s</div>' % esc(item["reason"]))
        if item["diff"]:
            out.append('<details class="diff"%s><summary>差分（%d行）</summary>%s</details>'
                       % (" open" if status == "pending" else "", len(item["diff"]),
                          render_diff([d["text"] for d in item["diff"]])))
        if item["sections"]:
            parts = []
            for sec in item["sections"]:
                if sec["title"]:
                    parts.append("<h3>%s</h3>" % esc(sec["title"]))
                parts.append('<div class="text">%s</div>' % esc(sec["text"]))
            out.append('<details class="others"><summary>その他の本文</summary>%s</details>' % "".join(parts))
        out.append('<p class="error" role="alert" hidden></p>')
        if p.status != "applied":
            nid = "note-" + item["id"]
            buttons = "".join('<button type="submit" name="to" value="%s" class="%s">%s</button>'
                              % (to, to, esc(BUTTON_LABEL[to]))
                              for to in ("approved", "hold", "rejected", "pending") if to != p.status)
            out.append(
                '<form class="decide" method="post" action="/p/%s/decide">'
                '<label for="%s">メモ（任意）</label>'
                '<p class="help" id="%s-help">却下の理由を書くと否認リストに残り、同じ趣旨の案が再び出されなくなります。</p>'
                '<textarea id="%s" name="note" aria-describedby="%s-help">%s</textarea>'
                '<div class="buttons">%s</div></form>'
                % (esc(slug), esc(nid), esc(nid), esc(nid), esc(nid), esc(item["note"]), buttons))
        out.append('<p class="detail-link"><a href="/p/%s">案の画面で開く</a></p>' % esc(slug))
        out.append("</article>")
        return "\n".join(out)

    def list_page(self, status):
        if status not in STATUS_ORDER:
            status = "pending"
        props = pl.list_proposals(self.directory)
        counts = dict((s, 0) for s in STATUS_ORDER)
        for p in props:
            counts[p.status] += 1
        tabs = []
        for s in STATUS_ORDER:
            cur = ' aria-current="page"' if s == status else ""
            tabs.append('<a href="/?status=%s" data-status="%s"%s>%s（<span class="count">%d</span>件）</a>'
                        % (s, s, cur, STATUS_LABEL[s], counts[s]))
        shown = [p for p in props if p.status == status]
        shown.sort(key=lambda p: p.name, reverse=(status != "pending"))
        if shown:
            content = "\n".join(self.render_card(p, status) for p in shown)
        else:
            content = '<p class="empty">%s</p>' % esc(empty_message(status))
        body = ('<p class="offline" id="offline" role="alert" hidden>'
                'サーバーに接続できません。再接続を試みています</p>\n'
                '<h1>承認待ちの変更</h1>\n<nav class="tabs" aria-label="状態">%s</nav>\n'
                '<div class="cards" id="cards" data-status="%s">\n%s\n</div>\n'
                '<div class="toast" id="toast" role="status" aria-live="polite" hidden></div>'
                % ("".join(tabs), status, content))
        self.send(200, page(STATUS_LABEL[status], body, script=True))

    def detail_page(self, name, done):
        path = pl.safe_path(self.directory, name)
        if path is None:
            return self.error_page(404, "案が見つかりません", "指定された案はありません。一覧から選び直してください。")
        p = pl.read_proposal(path)
        if not p.valid:
            return self.error_page(404, "案を読み込めません", "案のファイルの先頭（frontmatter）が正しくありません。")
        meta = p.meta
        dl = [
            "<dt>番号</dt><dd>%s</dd>" % esc(p.number),
            '<dt>状態</dt><dd><span class="status">%s</span></dd>' % esc(STATUS_LABEL.get(p.status, p.status)),
            '<dt>対象</dt><dd class="path">%s</dd>' % ("<br>".join(esc(t) for t in meta.get("targets") or []) or "なし"),
            "<dt>作成日時</dt><dd>%s</dd>" % esc(meta.get("created", "")),
            "<dt>出した元</dt><dd>%s</dd>" % esc(meta.get("source", "")),
        ]
        if meta.get("decided"):
            dl.append("<dt>判断した日時</dt><dd>%s</dd>" % esc(meta.get("decided")))
        if meta.get("note"):
            dl.append('<dt>メモ</dt><dd class="text">%s</dd>' % esc(meta.get("note")))
        msg = ""
        if done in DONE_MESSAGE:
            msg = '<p class="message" role="status">%s</p>' % esc(DONE_MESSAGE[done])
        if p.status == "applied":
            form = '<p class="readonly">この案は反映済みのため、変更できません。</p>'
        else:
            buttons = []
            for to in ("approved", "hold", "rejected", "pending"):
                if to == p.status:
                    continue
                buttons.append('<button type="submit" name="to" value="%s" class="%s">%s</button>'
                               % (to, to, esc(BUTTON_LABEL[to])))
            form = (
                '<form class="decide" method="post" action="/p/%s/decide">\n'
                '<label for="note">メモ（任意）</label>\n'
                '<p class="help" id="note-help">却下の理由を書くと否認リストに残り、同じ趣旨の案が再び出されなくなります。</p>\n'
                '<textarea id="note" name="note" aria-describedby="note-help">%s</textarea>\n'
                '<div class="buttons">%s</div>\n</form>'
                % (esc(urllib.parse.quote(p.name[:-3])), esc(meta.get("note", "")), "".join(buttons)))
        body = ('<p><a href="/?status=%s">%sの一覧へ戻る</a></p>\n%s\n<h1>%s</h1>\n<dl class="meta">%s</dl>\n%s\n%s'
                % (esc(p.status), esc(STATUS_LABEL.get(p.status, "承認待ち")), msg,
                   esc(p.heading or p.number), "".join(dl), render_body(p.body), form))
        self.send(200, page(p.heading or p.number, body))

    def api_decide(self, name):
        """JSON で受けた判断を記録し、更新後の案を JSON で返す。"""
        def fail(code, message):
            self.send(code, json.dumps({"error": message}, ensure_ascii=False), "application/json; charset=utf-8")

        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            return fail(415, "Content-Type は application/json にしてください")
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = 0
        if length < 0 or length > 64 * 1024:
            return fail(413, "メモが長すぎます。短くしてから、もう一度送ってください")
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return fail(400, "送られた内容を読み取れません")
        if not isinstance(data, dict) or not isinstance(data.get("to"), str) \
                or not isinstance(data.get("note", ""), str):
            return fail(400, "送られた内容を読み取れません")
        to = data["to"]
        with DECIDE_LOCK:
            try:
                p = pl.decide(self.directory, name, to, data.get("note", ""))
            except LookupError:
                return fail(404, "案が見つかりません。一覧を開き直してください")
            except PermissionError:
                return fail(409, "この案は反映済みのため、変更できません")
            except ValueError as e:
                return fail(400, "%s。一覧を開き直してから、もう一度操作してください" % e)
        log("判断を記録しました: %s -> %s" % (p.id, to))
        self.send(200, json.dumps(proposal_item(p), ensure_ascii=False), "application/json; charset=utf-8")

    # ---- POST ----
    def do_POST(self):
        if not self.host_ok() or not self.origin_ok():
            log("拒否しました: POST %s（Host=%s Origin=%s Referer=%s）" % (
                self.path, self.headers.get("Host"), self.headers.get("Origin"), self.headers.get("Referer")))
            return self.forbidden()
        u = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(u.path)
        m = re.match(r"^/api/proposals/([^/]+)/decide$", path)
        if m:
            return self.api_decide(m.group(1))
        if path.startswith("/api/"):
            return self.send(404, json.dumps({"error": "案が見つかりません。一覧を開き直してください"}, ensure_ascii=False),
                             "application/json; charset=utf-8")
        m = re.match(r"^/p/([^/]+)/decide$", path)
        if not m:
            return self.error_page(404, "ページが見つかりません", "指定されたページはありません。")
        name = m.group(1)
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = 0
        if length < 0 or length > 64 * 1024:
            return self.error_page(413, "メモが長すぎます", "メモを短くしてから、もう一度送ってください。")
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        form = urllib.parse.parse_qs(raw, keep_blank_values=True)
        to = (form.get("to") or [""])[0]
        note = (form.get("note") or [""])[0]
        with DECIDE_LOCK:
            try:
                p = pl.decide(self.directory, name, to, note)
            except LookupError:
                return self.error_page(404, "案が見つかりません", "指定された案はありません。一覧から選び直してください。")
            except PermissionError:
                return self.error_page(409, "変更できません", "この案は反映済みのため、変更できません。")
            except ValueError as e:
                return self.error_page(400, "受け付けられません", "%s。画面を開き直してから、もう一度操作してください。" % e)
        log("判断を記録しました: %s -> %s" % (p.id, to))
        loc = "/p/%s?done=%s" % (urllib.parse.quote(p.name[:-3]), to)
        self.send(303, page("移動します", '<p><a href="%s">案の画面へ移動します</a></p>' % esc(loc)),
                  extra={"Location": loc})


def main():
    port = int(os.environ.get("CLAUDE_REVIEW_PORT") or "8010")
    interval = float(os.environ.get("CLAUDE_REVIEW_SCAN_INTERVAL") or "10")
    directory = pl.proposals_dir()
    os.makedirs(directory, exist_ok=True)
    os.makedirs(pl.state_dir(), exist_ok=True)
    pl.ensure_rejections(directory)
    httpd = ThreadingHTTPServer((HOST, port), Handler)
    httpd.daemon_threads = True
    httpd.proposals_dir = directory
    base_url = "http://%s:%d" % (HOST, httpd.server_address[1])
    watcher = Watcher(directory, Notifier(base_url), interval)
    watcher.start()
    log("起動しました: %s/（案の置き場所: %s、状態: %s）" % (base_url, directory, pl.state_dir()))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        watcher.stop_event.set()
        httpd.server_close()
        log("停止しました")


if __name__ == "__main__":
    main()
