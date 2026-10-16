"""承認された案の差分を、対象のファイルへ patch で当てる（画面の「承認して反映」）。

Python 3.9 の標準ライブラリと /usr/bin/patch だけで動く。claude コマンドは使わない。
サーバー（core/server/inbox_server.py）から読み込む。

処理の順序（SKILL.md「4. 反映」）:
  1. status を approved にして台帳に記録する（proposal_lib.decide）。
  2. 差分を読み取れるか・書き込む先が許されるか（改ざん対策）を確かめる（blockers）。当たれば approved のまま残す。
     移し先への追記・索引の行の削除・スキルの全ファイルの削除は案の差分に入っており、判断を挟まずにそのまま反映する。
  3. approved.py と同じ判定（approved.judge）を通ることを確かめる。
  4. 各ファイルの一時的な複製へ patch を当て、今のファイルにそのまま当たるかを確かめる。
     1つでも当たらなければ何も書かず、status を hold にする。
  5. 直す前の版を <案の置き場所>/.backup/<YYYY-MM-DD>/ に複製してから、対象のファイルを置き換える。
  6. status を applied にし、applied の日時を書き、台帳に to: applied の行を足す。targets のフォルダ（スキルの削除）が
     空になっていれば消す。
  7. 途中で失敗したら、置き換えたファイルを複製から戻し、status を hold にする。
"""

import datetime
import fcntl
import os
import re
import shutil
import subprocess
import tempfile

import proposal_lib as pl
import approved as approved_mod

PATCH = os.environ.get("CLAUDE_REVIEW_PATCH") or "/usr/bin/patch"
FENCE_RE = re.compile(r"^(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)\s*$")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")

# 結果の種類
APPLIED = "applied"            # 反映できた
NEEDS_CLAUDE = "needs_claude"  # 自動では反映しない。approved のまま残す
MISMATCH = "hold"              # 差分が今のファイルと一致しなかった、または途中で失敗した。hold にした


class Result(object):
    def __init__(self, kind, reason, proposal):
        self.kind = kind
        self.reason = reason
        self.proposal = proposal


class FilePatch(object):
    """差分の1ファイル分。"""

    def __init__(self, old, new):
        self.old = old
        self.new = new
        self.path = new if old == "/dev/null" else old
        self.hunks = []  # (old_start, old_len, new_start, new_len, [行])

    @property
    def creates(self):
        return self.old == "/dev/null" or (len(self.hunks) == 1 and self.hunks[0][1] == 0 and self.hunks[0][0] == 0)

    @property
    def deletes(self):
        return self.new == "/dev/null" or (len(self.hunks) == 1 and self.hunks[0][3] == 0 and self.hunks[0][2] == 0)

    def text(self):
        out = ["--- %s" % self.path, "+++ %s" % self.path]
        for h in self.hunks:
            out.append("@@ -%d,%d +%d,%d @@" % h[:4])
            out.extend(h[4])
        return "\n".join(out) + "\n"

    def old_lines(self, hunk):
        return [ln[1:] for ln in hunk[4] if ln[:1] in (" ", "-")]


def diff_blocks(body):
    """本文の ```diff のコードブロックの中身をすべて返す（サーバーの parse_sections と同じ区切り方）。"""
    blocks = []
    lines = body.splitlines()
    i = 0
    while i < len(lines):
        m = FENCE_RE.match(lines[i])
        if m:
            closing = re.compile(r"^%s{%d,}\s*$" % (re.escape(m.group(1)[0]), len(m.group(1))))
            block = []
            i += 1
            while i < len(lines) and not closing.match(lines[i]):
                block.append(lines[i])
                i += 1
            if i >= len(lines):
                raise ValueError("コードブロックが閉じていない")
            if m.group(2).lower() == "diff":
                blocks.append(block)
        i += 1
    return blocks


def _header_path(line):
    return line[4:].split("\t", 1)[0].rstrip()


def parse_diff(lines):
    """diff -u の行を FilePatch のリストにする。形が崩れていれば ValueError。"""
    files = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if line.strip() == "" or line.startswith("diff "):
            i += 1
            continue
        if not line.startswith("--- "):
            raise ValueError("差分の見出しの行がない（%d行目: %s）" % (i + 1, line[:60]))
        if i + 1 >= n or not lines[i + 1].startswith("+++ "):
            raise ValueError("差分の +++ の行がない（%d行目）" % (i + 2))
        fp = FilePatch(_header_path(line), _header_path(lines[i + 1]))
        if fp.old != "/dev/null" and fp.new != "/dev/null" and fp.old != fp.new:
            raise ValueError("見出しの2行のパスが異なる（名前の変更は扱えない）: %s" % fp.old)
        if fp.old == "/dev/null" and fp.new == "/dev/null":
            raise ValueError("見出しの2行がどちらも /dev/null である")
        i += 2
        while i < n and lines[i].startswith("@@"):
            m = HUNK_RE.match(lines[i])
            if not m:
                raise ValueError("範囲の行が読めない（%d行目）" % (i + 1))
            os_, ol = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
            ns, nl = int(m.group(3)), int(m.group(4) if m.group(4) is not None else 1)
            i += 1
            body = []
            ro, rn = ol, nl
            while ro > 0 or rn > 0:
                if i >= n:
                    raise ValueError("差分の行数が範囲の行と合わない（%s）" % fp.path)
                ln = lines[i]
                if ln == "":
                    ln = " "  # 末尾の空白が削られた空の文脈の行
                c = ln[0]
                if c == " ":
                    ro -= 1
                    rn -= 1
                elif c == "-":
                    ro -= 1
                elif c == "+":
                    rn -= 1
                elif c == "\\":
                    pass
                else:
                    raise ValueError("差分の行の先頭が読めない（%d行目）" % (i + 1))
                if ro < 0 or rn < 0:
                    raise ValueError("差分の行数が範囲の行と合わない（%s）" % fp.path)
                body.append(ln)
                i += 1
            while i < n and lines[i].startswith("\\"):
                body.append(lines[i])
                i += 1
            fp.hunks.append((os_, ol, ns, nl, body))
        if not fp.hunks:
            raise ValueError("差分に範囲の行がない（%s）" % fp.path)
        files.append(fp)
    if not files:
        raise ValueError("差分にファイルがない")
    return files


def home_dir():
    return os.path.realpath(os.path.expanduser("~"))


def _within(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def dir_targets(targets):
    """targets のうちフォルダのもの（スキルの削除の案）を返す。"""
    return [t for t in targets if os.path.isdir(t)]


def check_target(path, targets, directory, home):
    """差分のパスが書き込んでよい先かを確かめ、理由（だめなとき）か None を返す。"""
    if not path.startswith("/"):
        return "差分のパスが絶対パスではない: %s" % path
    if "\x00" in path or any(part == ".." for part in path.split("/")):
        return "差分のパスに .. が含まれている: %s" % path
    if path not in targets and not any(_within(path, d) for d in dir_targets(targets)):
        return "差分のファイルが targets に無い: %s" % path
    real = os.path.realpath(path)
    if not _within(real, home):
        return "書き込む先がホームの外にある: %s（実体 %s）" % (path, real)
    for guarded in (os.path.realpath(directory), os.path.realpath(pl.state_dir())):
        if _within(real, guarded):
            return "書き込む先が承認待ちの置き場所か台帳の置き場所の中にある: %s" % path
    if os.path.lexists(real) and not os.path.isfile(real):
        return "書き込む先がふつうのファイルではない（フォルダ等）: %s" % path
    return None


def blockers(proposal, directory, home=None):
    """自動で反映しない理由のリストと、読み取った差分を返す。理由が空なら自動で反映してよい。

    案は、移し先への追記・索引の行の削除・スキルの全ファイルの削除を含めた全差分を持つ。承認は差分の全体への承認であり、
    反映の段で Claude の判断（移し先の確認・「移さない」・削除の手段）を挟まない（2026-10-16 指示）。
    ここで止めるのは、差分を読み取れない案と、書き込む先が許されない案（改ざん対策）だけである。
    """
    home = home or home_dir()
    reasons = []
    meta = proposal.meta
    targets = [os.path.expanduser(t) for t in (meta.get("targets") or [])]
    files = []
    try:
        blocks = diff_blocks(proposal.body)
        if not blocks:
            raise ValueError("差分のブロックが無い")
        for b in blocks:
            files.extend(parse_diff(b))
    except ValueError as e:
        reasons.append("差分を読み取れない（%s）" % e)
        return reasons, []
    # 削除で消してよいのはふつうのファイルだけである。リンクを当てると、リンクの先（別の場所の実体）を消してしまう。
    for t in dir_targets(targets):
        if os.path.islink(t.rstrip("/")):
            reasons.append("targets のフォルダがリンクである（リンクの先の実体は消さない）: %s" % t)
    for fp in files:
        if fp.deletes and os.path.islink(fp.path):
            reasons.append("削除の対象がリンクである（リンクの先の実体は消さない）: %s" % fp.path)
        r = check_target(fp.path, targets, directory, home)
        if r:
            reasons.append(r)
    return reasons, files


def _count(haystack, needle):
    if not needle:
        return 0
    c = 0
    for k in range(len(haystack) - len(needle) + 1):
        if haystack[k:k + len(needle)] == needle:
            c += 1
    return c


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def prepare(files, work):
    """一時的な複製へ patch を当て、{実体のパス: 当てた後の内容（削除なら None）} を返す。

    当たらなければ ValueError。fuzz は許さない（-F 0）。行の位置のずれ（offset）は、
    その範囲の元の行の並びがファイルの中に1か所しか無いときだけ許す。
    """
    copies = {}  # 実体のパス -> 一時ファイル
    order = []
    for k, fp in enumerate(files):
        real = os.path.realpath(fp.path)
        if real not in copies:
            tmp = os.path.join(work, "f%d" % k)
            if os.path.exists(real):
                if fp.creates and os.path.getsize(real) > 0:
                    raise ValueError("新規作成の差分だが、ファイルが既にある: %s" % fp.path)
                if fp.creates:
                    pass  # 空のファイルは無いものとして作る
                else:
                    shutil.copyfile(real, tmp)
            elif not fp.creates:
                raise ValueError("対象のファイルが無い: %s" % fp.path)
            copies[real] = tmp
            order.append(real)
        tmp = copies[real]
        pfile = os.path.join(work, "p%d.diff" % k)
        with open(pfile, "w", encoding="utf-8") as f:
            f.write(fp.text())
        current = []
        if os.path.exists(tmp):
            current = _read_bytes(tmp).decode("utf-8", "replace").splitlines()
        env = dict(os.environ)
        env.pop("POSIXLY_CORRECT", None)
        r = subprocess.run([PATCH, "--verbose", "-u", "-F", "0", "-f", "-V", "none",
                            "-r", os.path.join(work, "r%d.rej" % k), "-i", pfile, tmp],
                           cwd=work, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        out = r.stdout.decode("utf-8", "replace")
        if r.returncode != 0:
            raise ValueError("差分が今のファイルと一致しない: %s" % fp.path)
        if re.search(r"with fuzz", out):
            raise ValueError("差分が今のファイルと一致しない（fuzz が必要）: %s" % fp.path)
        if re.search(r"\(offset -?\d+ lines?\)", out):
            for h in fp.hunks:
                if _count(current, fp.old_lines(h)) != 1:
                    raise ValueError("差分の位置がずれており、当てる場所を1か所に決められない: %s" % fp.path)
        if fp.deletes:
            if os.path.exists(tmp) and os.path.getsize(tmp) > 0:
                raise ValueError("削除の差分を当てた後にも内容が残る: %s" % fp.path)
            if os.path.exists(tmp):
                os.unlink(tmp)
    result = {}
    for real in order:
        tmp = copies[real]
        result[real] = _read_bytes(tmp) if os.path.exists(tmp) else None
    return order, result


def backup_name(home, real, pid):
    rel = os.path.relpath(real, home)
    flat = "__".join(part.lstrip(".") or part for part in rel.split("/"))
    return "%s__%s.bak" % (pid, flat)


def _write_bytes(path, data):
    d = os.path.dirname(path)
    mode = 0o644
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=".tmp-apply-", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def commit(order, result, directory, pid, home):
    """直す前の版を複製してから、対象のファイルを置き換える。途中で失敗したら戻して例外を投げ直す。"""
    day = datetime.date.today().isoformat()
    bdir = os.path.join(directory, ".backup", day)
    os.makedirs(bdir, exist_ok=True)
    done = []  # (実体のパス, 複製のパス or None, 作ったフォルダ)
    try:
        for real in order:
            backup = None
            if os.path.exists(real):
                backup = os.path.join(bdir, backup_name(home, real, pid))
                base, k = backup, 2
                while os.path.exists(backup):
                    backup = "%s.%d.bak" % (base[:-4], k)
                    k += 1
                shutil.copy2(real, backup)
            made = []
            parent = os.path.dirname(real)
            while not os.path.isdir(parent):
                made.append(parent)
                parent = os.path.dirname(parent)
            done.append((real, backup, made))
            for d in reversed(made):
                os.mkdir(d)
            data = result[real]
            if data is None:
                os.unlink(real)
            else:
                _write_bytes(real, data)
    except BaseException:
        rollback(done)
        raise
    return done


def rollback(done):
    for real, backup, made in reversed(done):
        try:
            if backup is not None:
                _write_bytes(real, _read_bytes(backup))
            elif os.path.exists(real):
                os.unlink(real)
            for d in made:
                try:
                    os.rmdir(d)
                except OSError:
                    pass
        except OSError:
            pass


class _FileLock(object):
    """台帳の置き場所の apply.lock で、別のプロセスと反映が重ならないようにする。"""

    def __enter__(self):
        os.makedirs(pl.state_dir(), exist_ok=True)
        self.f = open(os.path.join(pl.state_dir(), "apply.lock"), "a")
        fcntl.flock(self.f.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f.fileno(), fcntl.LOCK_UN)
        self.f.close()


def prune_empty_dirs(dirs):
    """スキルの削除の案で、全ファイルを消した後に空になったフォルダを消す。ファイルが残るフォルダは消さない。"""
    for d in dirs:
        if not os.path.isdir(d) or os.path.islink(d):
            continue
        for root, _subdirs, _files in os.walk(d, topdown=False):
            try:
                os.rmdir(root)
            except OSError:
                pass


def _hold(directory, name, reason, note):
    text = reason
    if note:
        text += "。承認時のメモ: " + note
    return pl.decide(directory, name, "hold", text)


def approve_and_apply(directory, name, note, home=None):
    """「承認して反映」1回分。Result を返す。案が無ければ LookupError、反映済みなら PermissionError。"""
    home = home or home_dir()
    note = (note or "").strip()
    with _FileLock():
        p = pl.decide(directory, name, "approved", note)
        reasons, files = blockers(p, directory, home)
        if reasons:
            return Result(NEEDS_CLAUDE, "、".join(reasons), p)
        ok, ng = approved_mod.judge([p], pl.latest_decisions())
        if not ok:
            return Result(NEEDS_CLAUDE, "承認の記録を確かめられない（%s）" % (ng[0][1] if ng else "不明"), p)
        stamp = pl.now_text()
        work = tempfile.mkdtemp(prefix="review-apply.")
        try:
            try:
                order, result = prepare(files, work)
            except (ValueError, OSError, subprocess.SubprocessError) as e:
                reason = "反映時に差分が今のファイルと一致しなかった（%s 確認。%s）" % (stamp, e)
                return Result(MISMATCH, reason, _hold(directory, name, reason, note))
            folders = dir_targets([os.path.expanduser(t) for t in (p.meta.get("targets") or [])])
            try:
                done = commit(order, result, directory, p.id, home)
            except (OSError, ValueError) as e:
                reason = "反映の途中で失敗したため元に戻した（%s。%s）" % (stamp, e)
                return Result(MISMATCH, reason, _hold(directory, name, reason, note))
            try:
                newp = pl.mark_applied(p.path, stamp, note)
            except (OSError, ValueError) as e:
                rollback(done)
                reason = "反映済みの記録に失敗したため元に戻した（%s。%s）" % (stamp, e)
                return Result(MISMATCH, reason, _hold(directory, name, reason, note))
            # 戻す必要が無くなってから消す（戻すときに元のフォルダが要るため）。
            prune_empty_dirs(folders)
            return Result(APPLIED, "", newp)
        finally:
            shutil.rmtree(work, ignore_errors=True)
