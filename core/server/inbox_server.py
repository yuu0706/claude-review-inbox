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
  CLAUDE_REPORTS_ROOT          定期実行のレポートの置き場所（既定 ~/claude-reports）
  CLAUDE_REPORTS_STATE         レポートの既読の記録の置き場所（既定 ~/.local/state/claude-reports）
  CLAUDE_SKILLS_DIR            閲覧するスキルの置き場所（既定 ${CLAUDE_CONFIG_DIR:-~/.claude}/skills）
  CLAUDE_SKILLS_EXCLUDE        スキルの一覧で数えないディレクトリ名を足す（カンマ区切り）
"""

import datetime
import hmac
import html
import json
import os
import posixpath
import re
import secrets
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
import apply_lib  # noqa: E402
sys.path.insert(0, HERE)
import markdown_lite  # noqa: E402

HOST = "127.0.0.1"
STATUS_ORDER = ("pending", "approved", "hold", "rejected", "applied")
STATUS_LABEL = {
    "pending": "承認待ち",
    "approved": "承認済み",
    "hold": "保留",
    "rejected": "却下",
    "applied": "反映済み",
}
# ボタンの文言。押した結果の状態ごとに持つ。apply は「承認して反映」（承認の記録に続けて差分を当てる）。
BUTTON_LABEL = {
    "apply": "承認して反映",
    "hold": "保留にする",
    "rejected": "却下する",
    "pending": "承認待ちに戻す",
}
BUTTON_ORDER = ("apply", "hold", "rejected", "pending")
DONE_MESSAGE = {
    "approved": "承認しました。反映は会話で「承認分を反映して」と伝えると行われます。",
    "hold": "保留にしました。",
    "rejected": "却下しました。否認リストに記録しました。",
    "pending": "承認待ちに戻しました。",
}
# 「承認して反映」の結果ごとの文言。%s には理由が入る。
APPLY_MESSAGE = {
    apply_lib.APPLIED: "承認して反映しました。対象のファイルを差分のとおりに直しました。",
    apply_lib.NEEDS_CLAUDE: "承認しました。この案は Claude による反映が必要です（%s）。会話で「承認分を反映して」と伝えてください。",
    apply_lib.MISMATCH: "差分が今のファイルと一致しなかったため、反映せずに保留にしました（%s）。",
}
NEEDS_CLAUDE_LABEL = "Claude による反映が必要です（%s）。会話で「承認分を反映して」と伝えてください。"
DECIDE_LOCK = threading.Lock()
REPORTS_LOCK = threading.Lock()

# ---- 定期実行のレポート ----
# 置き場所・名前の形・既読の記録の決まりは core/skills/report-inbox/scripts/lib.sh と同じにする。
# サーバーはシェルを起動せずに一覧を返すため、lib.sh を呼ばずにここで同じ決まりを持つ。
REPORT_NAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})(?:-(\d+))?\.md$")
PROPOSALS_JOB = "proposals"
REPORT_VIEWS = ("unread", "all")
REPORT_VIEW_LABEL = {"unread": "未読", "all": "すべて"}
REPORT_MAX_PATHS = 10000


def reports_root():
    """レポートの置き場所の実体の絶対パス。ディレクトリが無ければ None。"""
    root = os.environ.get("CLAUDE_REPORTS_ROOT") or os.path.expanduser("~/claude-reports")
    if not os.path.isdir(root):
        return None
    return os.path.realpath(root)


def read_record_path():
    state = os.environ.get("CLAUDE_REPORTS_STATE") or os.path.expanduser("~/.local/state/claude-reports")
    return os.path.join(state.rstrip("/") or "/", "report-inbox", "read.txt")


def is_job_name(job):
    return bool(job) and not job.startswith(".") and job != PROPOSALS_JOB and "/" not in job


def report_jobs(root):
    """ジョブのディレクトリ名の一覧。承認待ちと「.」で始まるディレクトリは数えない。"""
    if root is None:
        return []
    try:
        names = os.listdir(root)
    except OSError:
        return []
    return sorted(n for n in names if is_job_name(n) and os.path.isdir(os.path.join(root, n)))


def report_real_path(root, job, name):
    """レポートの実体の絶対パス。レポートの条件に当たらない、または置き場所の外を指していれば None。"""
    if root is None or not is_job_name(job) or not REPORT_NAME_RE.match(name):
        return None
    path = os.path.join(root, job, name)
    # ジョブのディレクトリやファイルがシンボリックリンクで別の場所を指すものは扱わない。
    if os.path.realpath(path) != path or not os.path.isfile(path):
        return None
    return path


def load_read_set():
    try:
        with open(read_record_path(), "r", encoding="utf-8", errors="replace") as f:
            return set(line.rstrip("\n") for line in f if line.strip())
    except OSError:
        return set()


def list_reports(root):
    """レポートを日付の新しい順、同じ日付なら連番の大きい順、同じならジョブ名の順に返す。"""
    seen = load_read_set()
    out = []
    for job in report_jobs(root):
        try:
            names = os.listdir(os.path.join(root, job))
        except OSError:
            continue
        for name in names:
            m = REPORT_NAME_RE.match(name)
            path = report_real_path(root, job, name)
            if not m or path is None:
                continue
            out.append({"job": job, "name": name, "date": m.group(1), "seq": int(m.group(2) or "1"),
                        "path": path, "key": job + "/" + name, "read": path in seen})
    out.sort(key=lambda r: r["job"])
    out.sort(key=lambda r: (r["date"], r["seq"]), reverse=True)
    return out


def report_counts(reports):
    return {"unread": sum(1 for r in reports if not r["read"]), "all": len(reports)}


def mark_reports_read(paths):
    """実体の絶対パスを既読の記録へ追記し、新たに足した件数を返す。既に記録にあるものは足さない。"""
    record = read_record_path()
    with REPORTS_LOCK:
        os.makedirs(os.path.dirname(record), exist_ok=True)
        seen = load_read_set()
        new = []
        for p in paths:
            if p not in seen:
                seen.add(p)
                new.append(p)
        if not new:
            return 0
        lead = ""
        try:
            with open(record, "rb") as f:
                f.seek(0, os.SEEK_END)
                if f.tell() > 0:
                    f.seek(-1, os.SEEK_END)
                    if f.read(1) != b"\n":
                        lead = "\n"
        except OSError:
            pass
        with open(record, "a", encoding="utf-8") as f:
            f.write(lead + "".join(p + "\n" for p in new))
        return len(new)


def read_report_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as e:
        return "（本文を読み込めませんでした: %s）" % e


# ---- スキル ----
# 置き場所の直下で数えないディレクトリ名。環境に固有の名前は、公開版に入らない local/server/skills-exclude.txt
# （1行1件、「#」で始まる行と空行は無視）と、環境変数 CLAUDE_SKILLS_EXCLUDE（カンマ区切り）で足す。
SKILLS_EXCLUDE = ("synced",)
SKILLS_EXCLUDE_FILE = os.path.join(os.path.dirname(os.path.dirname(HERE)), "local", "server", "skills-exclude.txt")
SKILL_MD_PRUNE = ("history", "node_modules")
SKILL_MD_DEPTH = 3
SKILL_DESC_MAX = 200


def skills_dir_setting():
    """設定から決まるスキルの置き場所の実体の絶対パス（ディレクトリの有無は問わない）。"""
    root = os.environ.get("CLAUDE_SKILLS_DIR")
    if not root:
        config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        root = os.path.join(config, "skills")
    return os.path.realpath(os.path.expanduser(root))


def skills_root():
    """スキルの置き場所の実体の絶対パス。ディレクトリが無ければ None。"""
    root = skills_dir_setting()
    return root if os.path.isdir(root) else None


def skill_excludes():
    names = set(SKILLS_EXCLUDE)
    names.update(n.strip() for n in (os.environ.get("CLAUDE_SKILLS_EXCLUDE") or "").split(",") if n.strip())
    try:
        with open(SKILLS_EXCLUDE_FILE, "r", encoding="utf-8") as f:
            names.update(l.strip() for l in f if l.strip() and not l.strip().startswith("#"))
    except OSError:
        pass
    return names


def home_relative(path):
    home = os.path.realpath(os.path.expanduser("~"))
    if path == home or path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def list_skills(root):
    """スキルの一覧。{"name", "dir"（実体）, "link"（リンクなら先の表示用のパス、違えば空文字）} を名前の順に返す。"""
    if root is None:
        return []
    try:
        names = os.listdir(root)
    except OSError:
        return []
    excludes = skill_excludes()
    out = []
    for name in sorted(names):
        if name.startswith(".") or name in excludes:
            continue
        path = os.path.join(root, name)
        try:
            real = os.path.realpath(path)
            if not os.path.isdir(real) or not os.path.isfile(os.path.join(real, "SKILL.md")):
                continue
            link = home_relative(real) if os.path.islink(path) else ""
        except OSError:
            continue
        out.append({"name": name, "dir": real, "link": link})
    return out


def find_skill(name):
    for s in list_skills(skills_root()):
        if s["name"] == name:
            return s
    return None


def skill_md_files(skill_dir):
    """スキルの中の Markdown の相対パス（「/」区切り）。SKILL.md を先頭に、残りは名前の順に返す。"""
    found = []
    base_depth = skill_dir.rstrip(os.sep).count(os.sep)

    def walk_error(e):
        # os.walk の既定は一覧の失敗を黙って捨てるため、読めないスキルが「ファイルが無い」と同じ 404 になる。
        # スキルのディレクトリ自体の PermissionError だけは送出し、呼び出し側で macOS の制限として扱う。
        if isinstance(e, PermissionError) and os.path.realpath(e.filename or "") == skill_dir:
            raise e

    for dirpath, dirnames, filenames in os.walk(skill_dir, onerror=walk_error):
        depth = dirpath.rstrip(os.sep).count(os.sep) - base_depth
        dirnames[:] = [] if depth + 1 >= SKILL_MD_DEPTH else sorted(
            d for d in dirnames if not d.startswith(".") and d not in SKILL_MD_PRUNE)
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            path = os.path.join(dirpath, fn)
            real = os.path.realpath(path)
            if not real.startswith(skill_dir + os.sep) or not os.path.isfile(real):
                continue
            found.append(os.path.relpath(path, skill_dir).replace(os.sep, "/"))
    found.sort(key=lambda r: (r != "SKILL.md", r))
    return found


def skill_md_path(skill, rel):
    """スキルの中の Markdown の実体のパス。3.2 の条件に当たらなければ None。"""
    if not rel.endswith(".md") or rel.startswith("/") or "\\" in rel or ".." in rel.split("/"):
        return None
    if rel not in skill_md_files(skill["dir"]):
        return None
    real = os.path.realpath(os.path.join(skill["dir"], rel))
    if not real.startswith(skill["dir"] + os.sep):
        return None
    return real


def split_frontmatter(text):
    """先頭の前付けを [(キー, 値)] と本文に分ける。前付けが無ければ空の一覧と元の文を返す。"""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return [], text
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() in ("---", "..."):
            end = i
            break
    if end is None:
        return [], text
    items = []
    for line in lines[1:end]:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            value = m.group(2).strip()
            if value in (">", "|", ">-", "|-"):
                value = ""
            items.append([m.group(1), value])
        elif items and line.strip():
            # 字下げした続きの行と、一覧（- の行）は前のキーの値に足す。
            items[-1][1] = (items[-1][1] + " " + line.strip()).strip()
    for it in items:
        v = it[1]
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            it[1] = v[1:-1]
    return [tuple(it) for it in items], "\n".join(lines[end + 1:])


def skill_description(skill):
    """SKILL.md の前付けの description。macOS の制限などで読めないときは None を返す。"""
    try:
        with open(os.path.join(skill["dir"], "SKILL.md"), "r", encoding="utf-8", errors="replace") as f:
            meta, _ = split_frontmatter(f.read())
    except PermissionError:
        return None
    except OSError:
        return ""
    return dict(meta).get("description", "")


def short_text(text, limit=SKILL_DESC_MAX):
    return text if len(text) <= limit else text[:limit] + "…"


def switch_nav(current, unread, skills=None, reports=True):
    """「承認待ち」「レポート」「スキル」を切り替えるトグル。skills が None ならスキルの項目を出さない。"""
    links = [("proposals", "/", "承認待ち")]
    if reports:
        links.append(("reports", "/reports", 'レポート（未読 <span class="unread-count">%d</span> 件）' % unread))
    if skills:
        links.append(("skills", "/skills", "スキル（%d 件）" % skills))
    if len(links) < 2:
        return ""
    out = []
    for key, href, label in links:
        cur = ' aria-current="page"' if key == current else ""
        out.append('<a href="%s"%s>%s</a>' % (href, cur, label))
    return '<nav class="switch" aria-label="表示の切り替え">%s</nav>\n' % "".join(out)


def buttons_for(status):
    """今の状態で出すボタン。承認済みの案にも「承認して反映」を出す（反映をやり直せるようにする）。"""
    return [to for to in BUTTON_ORDER if to != status]


def apply_message(kind, reason):
    msg = APPLY_MESSAGE[kind]
    return msg % reason if "%s" in msg else msg


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
.needs { border: 1px solid var(--warn); color: var(--warn); border-radius: 6px; padding: 6px 10px; margin: 8px 0; }
.message.needs_claude, .message.hold { border-color: var(--warn); color: var(--warn); }
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
nav.switch { display: inline-flex; flex-wrap: wrap; border: 1px solid var(--line); border-radius: 8px; overflow: hidden;
  margin: 4px 0 0; }
nav.switch a { padding: 6px 14px; text-decoration: none; color: var(--fg); }
nav.switch a + a { border-left: 1px solid var(--line); }
nav.switch a[aria-current="page"] { background: var(--accent); color: var(--bg); font-weight: bold; }
.report-actions { margin: 0 0 12px; }
pre.report-body { white-space: pre-wrap; word-break: break-word; overflow-x: visible; }
.card.read .status { color: var(--muted); }
.filter { margin: 0 0 12px; }
.filter label { display: block; font-weight: bold; margin-bottom: 4px; }
.filter input { width: 100%; max-width: 32em; font: inherit; color: var(--fg); background: var(--bg);
  border: 1px solid var(--line); border-radius: 6px; padding: 6px; }
.filter p { margin: 4px 0 0; font-size: 0.85rem; }
.card.skill h2 a { text-decoration: none; }
.card.skill p.text { margin: 6px 0 0; }
.card[hidden] { display: none; }
h1 .path { font-size: 0.9rem; color: var(--muted); font-weight: normal; }
nav.skill-files ul { margin: 0 0 12px; padding-left: 1.4em; }
nav.skill-files a[aria-current="page"] { font-weight: bold; }
table.frontmatter { margin: 0 0 16px; }
table.frontmatter th { white-space: nowrap; width: 1%; }
table.frontmatter td { word-break: break-word; }
.markdown { min-width: 0; overflow-wrap: break-word; }
.markdown h1 { font-size: 1.3rem; } .markdown h2 { font-size: 1.15rem; } .markdown h3 { font-size: 1rem; }
.markdown h4, .markdown h5, .markdown h6 { font-size: 0.95rem; margin: 12px 0 6px; }
.markdown code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85em;
  background: var(--card); border: 1px solid var(--line); border-radius: 4px; padding: 0 3px; }
.markdown pre code { border: none; padding: 0; background: none; font-size: inherit; }
.markdown blockquote { margin: 8px 0; padding: 0 12px; border-left: 4px solid var(--line); color: var(--muted); }
.markdown hr { border: none; border-top: 1px solid var(--line); margin: 16px 0; }
.md-table { overflow-x: auto; margin: 8px 0; }
.md-table table { width: auto; min-width: 100%; }
.md-table th, .md-table td { border: 1px solid var(--line); }
@media (max-width: 480px) { main { padding: 12px 10px 64px; } .card { padding: 10px; } }
"""


def page(title, body, script=False, token="", site="承認待ちの変更"):
    """script は True で app.js、文字列ならその名前の static のスクリプトを読み込む。"""
    if script:
        tag = '<script src="/static/%s" defer></script>\n' % ("app.js" if script is True else script)
    else:
        tag = ""
    if token:
        tag = '<meta name="review-token" content="%s">\n' % esc(token) + tag
    return (
        "<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        "<title>%s | %s</title>\n<style>%s</style>\n%s</head>\n<body>\n<main>\n%s\n</main>\n</body>\n</html>\n"
        % (esc(title), esc(site), CSS, tag, body)
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


def apply_block(p):
    """承認済みの案が自動では反映できない理由（1行）。反映できる案と承認済み以外の案では空文字。"""
    if p.status != "approved":
        return ""
    reasons, _ = apply_lib.blockers(p, os.path.dirname(p.path))
    return "、".join(reasons)


def proposal_item(p):
    """一覧と判断の API が返す案の1件分。"""
    reason, diff, others = parse_sections(p.body)
    meta = p.meta
    return {
        "apply_block": apply_block(p),
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

    def error_page(self, code, title, message, back=("/", "承認待ちの一覧へ戻る")):
        body = '<h1>%s</h1>\n<p>%s</p>\n<p><a href="%s">%s</a></p>' % (esc(title), esc(message), esc(back[0]), esc(back[1]))
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
        if path == "/reports":
            return self.reports_page((q.get("view") or ["unread"])[0], (q.get("read") or [""])[0],
                                     (q.get("read_all") or [""])[0])
        if path == "/skills" or path == "/skills/":
            return self.skills_page()
        if path.startswith("/skills/"):
            name, _, rel = path[len("/skills/"):].partition("/")
            return self.skill_page(name, rel or "SKILL.md")
        if path.startswith("/static/"):
            return self.static_file(path[len("/static/"):])
        if path.startswith("/p/"):
            return self.detail_page(path[3:], (q.get("done") or [""])[0])
        return self.error_page(404, "ページが見つかりません", "指定されたページはありません。")

    def api_list(self):
        items = [proposal_item(p) for p in pl.list_proposals(self.directory)]
        self.send(200, json.dumps(items, ensure_ascii=False), "application/json; charset=utf-8")

    def static_file(self, name):
        if name not in ("app.js", "reports.js", "skills.js"):
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
        if item["apply_block"]:
            out.append('<p class="needs">%s</p>' % esc(NEEDS_CLAUDE_LABEL % item["apply_block"]))
        out.append('<p class="error" role="alert" hidden></p>')
        if p.status != "applied":
            nid = "note-" + item["id"]
            buttons = "".join('<button type="submit" name="to" value="%s" class="%s">%s</button>'
                              % (to, to, esc(BUTTON_LABEL[to])) for to in buttons_for(p.status))
            out.append(
                '<form class="decide" method="post" action="/p/%s/decide">'
                '<input type="hidden" name="token" value="%s">'
                '<label for="%s">メモ（任意）</label>'
                '<p class="help" id="%s-help">却下の理由を書くと否認リストに残り、同じ趣旨の案が再び出されなくなります。</p>'
                '<textarea id="%s" name="note" aria-describedby="%s-help">%s</textarea>'
                '<div class="buttons">%s</div></form>'
                % (esc(slug), esc(self.server.token), esc(nid), esc(nid), esc(nid), esc(nid), esc(item["note"]), buttons))
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
                '%s<h1>承認待ちの変更</h1>\n<nav class="tabs" aria-label="状態">%s</nav>\n'
                '<div class="cards" id="cards" data-status="%s">\n%s\n</div>\n'
                '<div class="toast" id="toast" role="status" aria-live="polite" hidden></div>'
                % (self.switch_for("proposals"), "".join(tabs), status, content))
        self.send(200, page(STATUS_LABEL[status], body, script=True, token=self.server.token))

    # ---- 定期実行のレポート ----
    def switch_for(self, current):
        """トグルの HTML。レポートの項目はジョブがあるとき、スキルの項目はスキルがあるときだけ出す。

        どちらも無ければ空文字を返す。
        """
        root = reports_root()
        has_reports = bool(report_jobs(root))
        unread = report_counts(list_reports(root))["unread"] if has_reports else 0
        return switch_nav(current, unread, len(list_skills(skills_root())), has_reports)

    def render_report_card(self, r):
        """レポートの一覧のカード1件。JavaScript が動かないときも、フォームの POST で既読にできる。"""
        state = "既読" if r["read"] else "未読"
        facts = [("ジョブ", esc(r["job"])), ("日付", esc(r["date"])),
                 ("ファイル", '<span class="path">%s</span>' % esc(r["name"]))]
        out = [
            '<article class="card report%s" id="%s" data-path="%s" data-read="%d">'
            % (" read" if r["read"] else "", esc("report-" + r["key"]), esc(r["key"]), 1 if r["read"] else 0),
            '<div class="card-head"><span class="num">%s</span><h2>%s</h2><span class="status">%s</span></div>'
            % (esc(r["date"]), esc(r["job"]), state),
            '<dl class="facts">%s</dl>' % "".join("<dt>%s</dt><dd>%s</dd>" % f for f in facts),
            '<details class="report"><summary>本文</summary><pre class="report-body">%s</pre></details>'
            % esc(read_report_text(r["path"])),
            '<p class="error" role="alert" hidden></p>',
        ]
        if not r["read"]:
            out.append(
                '<form class="mark-read" method="post" action="/api/reports/read">'
                '<input type="hidden" name="token" value="%s">'
                '<input type="hidden" name="path" value="%s">'
                '<div class="buttons"><button type="submit">既読にする</button></div></form>'
                % (esc(self.server.token), esc(r["key"])))
        out.append("</article>")
        return "\n".join(out)

    def reports_page(self, view, read_key, read_all):
        if view not in REPORT_VIEWS:
            view = "unread"
        root = reports_root()
        reports = list_reports(root)
        counts = report_counts(reports)
        tabs = []
        for v in REPORT_VIEWS:
            cur = ' aria-current="page"' if v == view else ""
            tabs.append('<a href="/reports?view=%s" data-view="%s"%s>%s（<span class="count">%d</span>件）</a>'
                        % (v, v, cur, REPORT_VIEW_LABEL[v], counts[v]))
        shown = [r for r in reports if view == "all" or not r["read"]]
        if shown:
            content = "\n".join(self.render_report_card(r) for r in shown)
        elif view == "unread":
            content = '<p class="empty">未読のレポートはありません。</p>'
        else:
            content = '<p class="empty">レポートはありません。</p>'
        msg = ""
        if read_key and any(r["key"] == read_key for r in reports):
            job, name = read_key.split("/", 1)
            msg = '<p class="message" role="status">%s %s を既読にしました。</p>' % (esc(job), esc(name))
        elif read_all.isdigit():
            msg = '<p class="message" role="status">未読のレポート %d 件を既読にしました。</p>' % int(read_all)
        action = ""
        if counts["unread"] > 0:
            action = ('<form class="report-actions" id="mark-all" method="post" action="/api/reports/read">'
                      '<input type="hidden" name="token" value="%s"><input type="hidden" name="all" value="1">'
                      '<button type="submit">未読をすべて既読にする</button></form>\n' % esc(self.server.token))
        switch = self.switch_for("reports")
        body = ('%s<h1>定期実行のレポート</h1>\n%s<nav class="tabs" aria-label="表示">%s</nav>\n%s'
                '<div class="cards" id="report-cards" data-view="%s">\n%s\n</div>\n'
                '<div class="toast" id="toast" role="status" aria-live="polite" hidden></div>'
                % (switch, msg, "".join(tabs), action, view, content))
        self.send(200, page(REPORT_VIEW_LABEL[view], body, script="reports.js", token=self.server.token,
                            site="定期実行のレポート"))

    # ---- スキル ----
    def skills_page(self):
        skills = list_skills(skills_root())
        cards = []
        for s in skills:
            desc = skill_description(s)
            if desc is None:
                desc, desc_html = "", '<span class="readonly">macOS の制限で説明を読み込めません。</span>'
            else:
                desc_html = esc(short_text(desc)) or '<span class="readonly">説明はありません。</span>'
            facts = ""
            if s["link"]:
                facts = '<dl class="facts"><dt>リンクの先</dt><dd class="path">%s</dd></dl>' % esc(s["link"])
            cards.append(
                '<article class="card skill" data-search="%s">'
                '<div class="card-head"><h2><a href="/skills/%s">%s</a></h2></div>%s'
                '<p class="text">%s</p></article>'
                % (esc((s["name"] + " " + desc).lower()), esc(urllib.parse.quote(s["name"])), esc(s["name"]), facts,
                   desc_html))
        if cards:
            content = "\n".join(cards)
        else:
            content = ('<p class="empty">スキルはありません。置き場所（%s）にスキルのフォルダを置くと、ここに表示されます。</p>'
                       % esc(home_relative(skills_dir_setting())))
        body = ('%s<h1>スキル</h1>\n'
                '<p class="readonly">スキルの置き場所: <span class="path">%s</span>（閲覧のみ）</p>\n'
                '<div class="filter" id="skill-filter" hidden><label for="skill-q">名前と説明で絞り込む</label>'
                '<input type="search" id="skill-q" autocomplete="off">'
                '<p class="readonly" id="skill-filter-status" role="status" aria-live="polite"></p></div>\n'
                '<div class="cards" id="skill-cards">\n%s\n</div>'
                % (self.switch_for("skills"), esc(home_relative(skills_root() or "") or "（ありません）"), content))
        self.send(200, page("一覧", body, script="skills.js", site="スキル"))

    def skill_page(self, name, rel):
        back = ("/skills", "スキルの一覧へ戻る")
        skill = find_skill(name)
        try:
            path = skill_md_path(skill, rel) if skill else None
            if path is None:
                return self.error_page(404, "スキルが見つかりません",
                                       "指定されたスキルまたはファイルはありません。スキルの一覧から選び直してください。", back)
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
            files = skill_md_files(skill["dir"])
        except PermissionError:
            return self.skill_restricted_page(skill)
        except OSError:
            return self.error_page(404, "スキルが見つかりません",
                                   "指定されたファイルを読み込めませんでした。画面を読み込み直しても表示されない場合は、"
                                   "ファイルを直接開いて確認してください。", back)
        qname = urllib.parse.quote(name)

        def href_for(r):
            return "/skills/%s/%s" % (qname, urllib.parse.quote(r))

        def link(url):
            target, _, frag = url.partition("#")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(rel), urllib.parse.unquote(target)))
            if resolved in files:
                return href_for(resolved) + ("#" + frag if frag else "")
            return None

        meta, md_body = split_frontmatter(text)
        items = []
        for r in files:
            if r == rel:
                items.append('<li><a href="%s" aria-current="page">%s</a>（表示中）</li>' % (esc(href_for(r)), esc(r)))
            else:
                items.append('<li><a href="%s">%s</a></li>' % (esc(href_for(r)), esc(r)))
        parts = ['%s<p><a href="/skills">スキルの一覧へ戻る</a></p>' % self.switch_for("skills"),
                 '<h1>%s <span class="path">%s</span></h1>' % (esc(name), esc(rel))]
        if skill["link"]:
            parts.append('<p class="readonly">リンクの先: <span class="path">%s</span></p>' % esc(skill["link"]))
        parts.append('<nav class="skill-files" aria-label="このスキルの Markdown"><ul>%s</ul></nav>' % "".join(items))
        if meta:
            parts.append('<table class="frontmatter"><tbody>%s</tbody></table>'
                         % "".join("<tr><th>%s</th><td>%s</td></tr>" % (esc(k), esc(v)) for k, v in meta))
        parts.append('<article class="markdown">%s</article>' % markdown_lite.render(md_body, link))
        self.send(200, page(name, "\n".join(parts), site="スキル"))

    def skill_restricted_page(self, skill):
        """launchd から起動したサーバーは書類・デスクトップ・ダウンロードの中を開けない（macOS の制限）。
        ファイルが無いのとは違うため、404 にせず実体の場所を案内する。"""
        body = ('%s<p><a href="/skills">スキルの一覧へ戻る</a></p>\n<h1>%s</h1>\n'
                '<p>このスキルは macOS の制限で読み込めません。書類・デスクトップ・ダウンロードのフォルダの中にあるファイルは、'
                'この画面からは開けません。</p>\n'
                '<p>実体の場所: <span class="path">%s</span></p>\n<p>中身はファイルを直接開いて確認してください。</p>'
                % (self.switch_for("skills"), esc(skill["name"]), esc(home_relative(skill["dir"]))))
        self.send(200, page(skill["name"], body, site="スキル"))

    def resolve_report_keys(self, data):
        """既読にする要求から実体のパスの一覧を作る。受け付けられなければ ValueError。"""
        root = reports_root()
        if data.get("all") is True:
            return [r["path"] for r in list_reports(root) if not r["read"]]
        keys = data.get("paths")
        if not isinstance(keys, list) or not keys or len(keys) > REPORT_MAX_PATHS:
            raise ValueError("既読にするレポートが指定されていません")
        paths = []
        for k in keys:
            if not isinstance(k, str) or k.count("/") != 1:
                raise ValueError("レポートではないものが指定されました")
            job, name = k.split("/")
            p = report_real_path(root, job, name)
            if p is None:
                raise ValueError("レポートではないものが指定されました")
            paths.append(p)
        return paths

    def reports_read(self):
        """POST /api/reports/read。JSON とフォームの送信の両方を受け付ける。"""
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype == "application/x-www-form-urlencoded":
            return self.form_reports_read()
        fail = self.json_fail
        data = self.read_json()
        if data is None:
            return
        if not self.token_ok(self.headers.get("X-Review-Token")):
            log("拒否しました: 既読の要求の合言葉が一致しません")
            return fail(403, "画面の有効期限が切れました。画面を開き直してから、もう一度操作してください")
        try:
            paths = self.resolve_report_keys(data)
        except ValueError as e:
            return fail(400, "%s。画面を開き直してから、もう一度操作してください" % e)
        n = mark_reports_read(paths)
        log("レポートを既読にしました: %d件" % n)
        counts = report_counts(list_reports(reports_root()))
        self.send(200, json.dumps({"marked": n, "counts": counts}, ensure_ascii=False),
                  "application/json; charset=utf-8")

    def form_reports_read(self):
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = 0
        if length < 0 or length > 64 * 1024:
            return self.error_page(413, "受け付けられません", "送られた内容が長すぎます。")
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", errors="replace"), keep_blank_values=True)
        if not self.token_ok((form.get("token") or [""])[0]):
            log("拒否しました: 既読の要求の合言葉が一致しません")
            return self.error_page(403, "受け付けられません", "画面の有効期限が切れました。画面を開き直してから、もう一度操作してください。")
        data = {"all": True} if (form.get("all") or [""])[0] == "1" else {"paths": form.get("path") or []}
        try:
            paths = self.resolve_report_keys(data)
        except ValueError as e:
            return self.error_page(400, "受け付けられません", "%s。画面を開き直してから、もう一度操作してください。" % e)
        n = mark_reports_read(paths)
        log("レポートを既読にしました: %d件" % n)
        if data.get("all"):
            loc = "/reports?view=unread&read_all=%d" % n
        else:
            loc = "/reports?view=unread&read=%s" % urllib.parse.quote(data["paths"][0])
        self.send(303, page("移動します", '<p><a href="%s">レポートの一覧へ移動します</a></p>' % esc(loc)),
                  extra={"Location": loc})

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
        block = apply_block(p)
        if done == apply_lib.APPLIED and p.status == "applied":
            msg = '<p class="message" role="status">%s</p>' % esc(apply_message(apply_lib.APPLIED, ""))
        elif done == apply_lib.NEEDS_CLAUDE and p.status == "approved":
            msg = '<p class="message needs_claude" role="status">%s</p>' % esc(
                apply_message(apply_lib.NEEDS_CLAUDE, block or "承認の記録を確かめられない"))
        elif done == "apply-hold" and p.status == "hold":
            msg = '<p class="message hold" role="status">%s</p>' % esc(
                apply_message(apply_lib.MISMATCH, meta.get("note", "")))
        elif done in DONE_MESSAGE:
            msg = '<p class="message" role="status">%s</p>' % esc(DONE_MESSAGE[done])
        if block and done != apply_lib.NEEDS_CLAUDE:
            msg += '<p class="needs">%s</p>' % esc(NEEDS_CLAUDE_LABEL % block)
        if p.status == "applied":
            form = '<p class="readonly">この案は反映済みのため、変更できません。</p>'
        else:
            buttons = ['<button type="submit" name="to" value="%s" class="%s">%s</button>'
                       % (to, to, esc(BUTTON_LABEL[to])) for to in buttons_for(p.status)]
            form = (
                '<form class="decide" method="post" action="/p/%s/decide">\n'
                '<input type="hidden" name="token" value="%s">\n'
                '<label for="note">メモ（任意）</label>\n'
                '<p class="help" id="note-help">却下の理由を書くと否認リストに残り、同じ趣旨の案が再び出されなくなります。</p>\n'
                '<textarea id="note" name="note" aria-describedby="note-help">%s</textarea>\n'
                '<div class="buttons">%s</div>\n</form>'
                % (esc(urllib.parse.quote(p.name[:-3])), esc(self.server.token), esc(meta.get("note", "")),
                   "".join(buttons)))
        body = ('<p><a href="/?status=%s">%sの一覧へ戻る</a></p>\n%s\n<h1>%s</h1>\n<dl class="meta">%s</dl>\n%s\n%s'
                % (esc(p.status), esc(STATUS_LABEL.get(p.status, "承認待ち")), msg,
                   esc(p.heading or p.number), "".join(dl), render_body(p.body), form))
        self.send(200, page(p.heading or p.number, body, token=self.server.token))

    def json_fail(self, code, message):
        self.send(code, json.dumps({"error": message}, ensure_ascii=False), "application/json; charset=utf-8")

    def read_json(self):
        """JSON の本文を読む。読めなければ応答を返して None を返す。"""
        fail = self.json_fail
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            fail(415, "Content-Type は application/json にしてください")
            return None
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = 0
        if length < 0 or length > 64 * 1024:
            fail(413, "メモが長すぎます。短くしてから、もう一度送ってください")
            return None
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            fail(400, "送られた内容を読み取れません")
            return None
        if not isinstance(data, dict) or not isinstance(data.get("note", ""), str):
            fail(400, "送られた内容を読み取れません")
            return None
        return data

    def token_ok(self, token):
        """ページに埋めた合言葉と一致するか。反映の要求だけに求める。"""
        return isinstance(token, str) and hmac.compare_digest(token.encode("utf-8"), self.server.token.encode("utf-8"))

    def run_apply(self, name, note):
        """「承認して反映」を1回行い、apply_lib.Result を返す。例外は呼び出し側で扱う。"""
        with DECIDE_LOCK:
            r = apply_lib.approve_and_apply(self.directory, name, note)
        log("承認して反映: %s -> %s%s" % (r.proposal.id, r.kind, ("（%s）" % r.reason) if r.reason else ""))
        return r

    def api_apply(self, name):
        """JSON で受けた「承認して反映」を行い、結果と更新後の案を JSON で返す。"""
        fail = self.json_fail
        data = self.read_json()
        if data is None:
            return
        if not self.token_ok(self.headers.get("X-Review-Token")):
            log("拒否しました: 反映の要求の合言葉が一致しません（%s）" % name)
            return fail(403, "画面の有効期限が切れました。画面を開き直してから、もう一度操作してください")
        try:
            r = self.run_apply(name, data.get("note", ""))
        except LookupError:
            return fail(404, "案が見つかりません。一覧を開き直してください")
        except PermissionError:
            return fail(409, "この案は反映済みです。一覧を開き直してください")
        except ValueError as e:
            return fail(400, "%s。一覧を開き直してから、もう一度操作してください" % e)
        out = {"result": r.kind, "reason": r.reason, "message": apply_message(r.kind, r.reason),
               "item": proposal_item(r.proposal)}
        self.send(200, json.dumps(out, ensure_ascii=False), "application/json; charset=utf-8")

    def api_decide(self, name):
        """JSON で受けた判断を記録し、更新後の案を JSON で返す。"""
        fail = self.json_fail
        data = self.read_json()
        if data is None:
            return
        if not isinstance(data.get("to"), str):
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
        if path == "/skills" or path.startswith("/skills/"):
            # スキルは見るだけ。編集・削除の操作は受け付けない。
            return self.send(405, page("受け付けられません", "<h1>受け付けられません</h1>\n<p>スキルは閲覧だけができます。</p>"),
                             extra={"Allow": "GET, HEAD"})
        if path == "/api/reports/read":
            return self.reports_read()
        m = re.match(r"^/api/proposals/([^/]+)/decide$", path)
        if m:
            return self.api_decide(m.group(1))
        m = re.match(r"^/api/proposals/([^/]+)/apply$", path)
        if m:
            return self.api_apply(m.group(1))
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
        if to == "apply":
            return self.form_apply(name, (form.get("token") or [""])[0], note)
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


    def form_apply(self, name, token, note):
        """フォームの POST で受けた「承認して反映」。結果は案の画面に出す。"""
        if not self.token_ok(token):
            log("拒否しました: 反映の要求の合言葉が一致しません（%s）" % name)
            return self.error_page(403, "受け付けられません", "画面の有効期限が切れました。画面を開き直してから、もう一度操作してください。")
        try:
            r = self.run_apply(name, note)
        except LookupError:
            return self.error_page(404, "案が見つかりません", "指定された案はありません。一覧から選び直してください。")
        except PermissionError:
            return self.error_page(409, "変更できません", "この案は反映済みのため、変更できません。")
        except ValueError as e:
            return self.error_page(400, "受け付けられません", "%s。画面を開き直してから、もう一度操作してください。" % e)
        done = "apply-hold" if r.kind == apply_lib.MISMATCH else r.kind
        loc = "/p/%s?done=%s" % (urllib.parse.quote(r.proposal.name[:-3]), done)
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
    # 「承認して反映」の要求に求める合言葉。起動のたびに作り直し、ページにだけ埋める。
    httpd.token = secrets.token_urlsafe(32)
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
