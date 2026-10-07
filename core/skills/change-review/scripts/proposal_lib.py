"""承認待ちの案（proposals/*.md）と判断の台帳（decisions.jsonl）を扱う共通部品。

Python 3.9 の標準ライブラリだけで動く。サーバー（core/server/inbox_server.py）と
承認済みの判定（approved.py）の両方から読み込む。
"""

import datetime
import hashlib
import json
import os
import re
import tempfile

STATUSES = ("pending", "approved", "hold", "rejected", "applied")
# 画面のボタンで移れる状態。applied は反映の手順（mark_applied）だけが書く。
DECIDABLE = ("pending", "approved", "hold", "rejected")
REJECTIONS_NAME = "rejections.md"
# ファイル名: <YYYY-MM-DD>-<連番2桁>[-<短い名前>].md
NAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}-\d{2})(-[A-Za-z0-9_-]+)?\.md$")
REJECTIONS_HEADER = (
    "# 否認リスト\n"
    "\n"
    "却下した変更の記録である。案を出す側は、出す前にこの表を読み、"
    "同じ対象・同じ趣旨の修正・削除を出さない。\n"
    "\n"
    "| ID | 対象 | 否認した変更の要約 | 理由（メモ） | 否認日 |\n"
    "| --- | --- | --- | --- | --- |\n"
)


def proposals_dir():
    d = os.environ.get("CLAUDE_REVIEW_PROPOSALS")
    if not d:
        root = os.environ.get("CLAUDE_REPORTS_ROOT") or os.path.expanduser("~/claude-reports")
        d = os.path.join(root, "proposals")
    return os.path.abspath(d)


def state_dir():
    d = os.environ.get("CLAUDE_REVIEW_STATE") or os.path.expanduser("~/.local/state/claude-review-inbox")
    return os.path.abspath(d)


def ledger_path():
    return os.path.join(state_dir(), "decisions.jsonl")


def now_text():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def split_frontmatter(text):
    """(frontmatter の行のリスト, 本文) を返す。frontmatter が無ければ (None, text)。

    frontmatter は 1 行目の --- から次の --- の行まで。本文は閉じの --- の行の次からである。
    """
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n").strip() != "---":
        return None, text
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r\n").strip() == "---":
            return lines[: i + 1], "".join(lines[i + 1:])
    return None, text


def body_sha256(text):
    """frontmatter を除いた本文の SHA-256（16 進）。"""
    _, body = split_frontmatter(text)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        try:
            return json.loads(v)
        except ValueError:
            return v[1:-1]
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("''", "'")
    return v


def parse_meta(fm_lines):
    """frontmatter の行から id・status・created・source・note・decided・targets を取り出す。"""
    meta = {"targets": []}
    in_targets = False
    for raw in fm_lines[1:-1]:
        line = raw.rstrip("\r\n")
        if in_targets and re.match(r"^[ \t]+- ", line):
            v = _unquote(re.sub(r"^[ \t]+- ", "", line))
            if v:
                meta["targets"].append(v)
            continue
        in_targets = False
        m = re.match(r"^([A-Za-z_]+):(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if key == "targets":
            val = val.strip()
            if val == "":
                in_targets = True
            else:
                val = val.strip("[]")
                meta["targets"] = [_unquote(x) for x in val.split(",") if x.strip()]
        else:
            meta[key] = _unquote(val)
    return meta


def heading_of(body):
    for line in body.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return ""


class Proposal(object):
    def __init__(self, path, text):
        self.path = path
        self.name = os.path.basename(path)
        m = NAME_RE.match(self.name)
        self.number = m.group(1) if m else self.name[:-3]
        self.text = text
        fm, body = split_frontmatter(text)
        self.fm_lines = fm
        self.body = body
        self.meta = parse_meta(fm) if fm else {"targets": []}
        self.id = self.meta.get("id") or self.number
        self.status = self.meta.get("status", "")
        self.heading = heading_of(body)
        self.sha256 = hashlib.sha256(body.encode("utf-8")).hexdigest()

    @property
    def valid(self):
        return self.fm_lines is not None and self.status in STATUSES


def is_proposal_name(name):
    return name != REJECTIONS_NAME and NAME_RE.match(name) is not None


def safe_path(directory, name):
    """フォルダの直下にある案のファイルのパスを返す。名前が不正、フォルダの外を指す場合は None。"""
    if not isinstance(name, str) or "/" in name or "\\" in name or ".." in name or "\x00" in name:
        return None
    if not name.endswith(".md"):
        name = name + ".md"
    if not is_proposal_name(name):
        return None
    base = os.path.realpath(directory)
    path = os.path.join(base, name)
    real = os.path.realpath(path)
    if os.path.dirname(real) != base:
        return None
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    return path


def read_proposal(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return Proposal(path, f.read())


def list_proposals(directory=None):
    directory = directory or proposals_dir()
    out = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return out
    for name in names:
        if not is_proposal_name(name):
            continue
        path = os.path.join(directory, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            p = read_proposal(path)
        except OSError:
            continue
        if p.valid:
            out.append(p)
    return out


def atomic_write(path, text):
    """同じフォルダの一時ファイルへ書き、rename で置き換える。元の権限を保つ。"""
    d = os.path.dirname(path)
    mode = None
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _yaml_str(v):
    return json.dumps(v, ensure_ascii=False)


def update_frontmatter(text, values):
    """values（キーの順を保つ (キー, 値の文字列) のリスト）の行だけを書き換えた全文を返す。

    無い行は閉じの --- の前に足す。同じキーの行が複数あれば最初の行だけを残す。
    """
    fm, body = split_frontmatter(text)
    if fm is None:
        raise ValueError("frontmatter がありません")
    newline = "\r\n" if fm[0].endswith("\r\n") else "\n"
    vals = dict(values)
    keys = [k for k, _ in values]
    key_re = re.compile(r"^(%s):" % "|".join(re.escape(k) for k in keys))
    done = set()
    out = [fm[0]]
    for raw in fm[1:-1]:
        m = key_re.match(raw)
        if m:
            key = m.group(1)
            if key in done:
                continue
            out.append("%s: %s%s" % (key, vals[key], newline))
            done.add(key)
        else:
            out.append(raw)
    for key in keys:
        if key not in done:
            out.append("%s: %s%s" % (key, vals[key], newline))
    out.append(fm[-1])
    return "".join(out) + body


def rewrite_frontmatter(text, status, note, decided):
    """status・note・decided の3行だけを書き換えた全文を返す。無い行は閉じの --- の前に足す。"""
    return update_frontmatter(text, [("status", status), ("note", _yaml_str(note)), ("decided", decided)])


def mark_applied(path, when, note):
    """反映が済んだ案を status: applied にし、applied の日時を書き、台帳に to: applied の行を足す。

    台帳へ書けなければ、案のファイルを元に戻して例外を投げ直す。
    """
    p = read_proposal(path)
    if p.status != "approved":
        raise ValueError("承認済みではない案は反映済みにできません")
    new_text = update_frontmatter(p.text, [("status", "applied"), ("applied", when)])
    atomic_write(path, new_text)
    newp = read_proposal(path)
    try:
        append_ledger(newp.id, "applied", note, newp.sha256)
    except BaseException:
        atomic_write(path, p.text)
        raise
    return newp


def _cell(v):
    return str(v).replace("\\", "\\\\").replace("|", "\\|").replace("\r", " ").replace("\n", " ").strip()


def ensure_rejections(directory):
    path = os.path.join(directory, REJECTIONS_NAME)
    if not os.path.exists(path):
        atomic_write(path, REJECTIONS_HEADER)
    return path


def _row_id(line):
    m = re.match(r"^\|\s*([^|]*?)\s*\|", line)
    return m.group(1) if m else None


def remove_rejection(directory, pid):
    path = ensure_rejections(directory)
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines(keepends=True)
    kept = [ln for ln in lines if _row_id(ln) != _cell(pid)]
    if len(kept) != len(lines):
        atomic_write(path, "".join(kept))


def add_rejection(directory, proposal, note, day):
    path = ensure_rejections(directory)
    remove_rejection(directory, proposal.id)
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if text and not text.endswith("\n"):
        text += "\n"
    row = "| %s | %s | %s | %s | %s |\n" % (
        _cell(proposal.id),
        _cell(", ".join(proposal.meta.get("targets") or [])),
        _cell(proposal.heading),
        _cell(note),
        _cell(day),
    )
    atomic_write(path, text + row)


def append_ledger(pid, to, note, sha):
    d = state_dir()
    os.makedirs(d, exist_ok=True)
    line = json.dumps({"id": pid, "to": to, "note": note, "sha256": sha, "at": now_iso()}, ensure_ascii=False)
    with open(ledger_path(), "a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())


def latest_decisions(path=None):
    """台帳から id ごとの最新の行を返す。読めない行は飛ばす。"""
    path = path or ledger_path()
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and isinstance(rec.get("id"), str):
                    out[rec["id"]] = rec
    except OSError:
        pass
    return out


def decide(directory, name, to, note):
    """ボタン1回分の処理。案のファイル・否認リスト・台帳を書き換え、書き換えた後の Proposal を返す。"""
    if to not in DECIDABLE:
        raise ValueError("状態が不正です: %s" % to)
    path = safe_path(directory, name)
    if path is None:
        raise LookupError(name)
    p = read_proposal(path)
    if not p.valid:
        raise ValueError("frontmatter が不正です")
    if p.status == "applied":
        raise PermissionError("反映済みの案は変更できません")
    note = (note or "").strip()
    new_text = rewrite_frontmatter(p.text, to, note, now_text())
    atomic_write(path, new_text)
    day = datetime.date.today().isoformat()
    if to == "rejected":
        add_rejection(directory, p, note, day)
    elif p.status == "rejected":
        remove_rejection(directory, p.id)
    newp = read_proposal(path)
    append_ledger(newp.id, to, note, newp.sha256)
    return newp
