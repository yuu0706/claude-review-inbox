"""外部から入れたスキルに上流の新しい版が出ていないかを確かめる。run-if-due.sh から呼ばれる。

標準出力には、新しい版があるときだけ SessionStart の hook の JSON を1つ出す。それ以外は何も出さない。
終了コード: 0 確認できた（新しい版の有無は問わない） / 1 確認できなかった（ネットワーク・ロックファイルの誤りなど）。
理由は標準エラーに1行で出す。呼び出し元がログに残す。

環境変数（既定値は括弧内）:
  SKILL_UPDATES_LOCK        ロックファイル（~/skills-lock.json）
  SKILL_UPDATES_SKILLS_DIR  スキルの実体の置き場所（~/.agents/skills）
  SKILL_UPDATES_STATE       記録の置き場所（~/.local/state/claude-reports/skill-updates）
  CLAUDE_REPORTS_ROOT       結果の置き場所の親（~/claude-reports）
  SKILL_UPDATES_DEADLINE    全体の打ち切りの秒数（8）
  SKILL_UPDATES_API         GitHub API の応答を返すコマンド。API のパス（例 repos/o/r/commits?...）を
                            引数に受け、JSON を標準出力に出す。検査で差し替えるために使う
  SKILL_UPDATES_TODAY       今日の日付（YYYY-MM-DD）。検査用
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse

HOME = os.path.expanduser("~")
LOCK = os.environ.get("SKILL_UPDATES_LOCK") or os.path.join(HOME, "skills-lock.json")
SKILLS_DIR = os.environ.get("SKILL_UPDATES_SKILLS_DIR") or os.path.join(HOME, ".agents", "skills")
STATE_DIR = os.environ.get("SKILL_UPDATES_STATE") or os.path.join(
    HOME, ".local", "state", "claude-reports", "skill-updates")
REPORTS_DIR = os.path.join(
    (os.environ.get("CLAUDE_REPORTS_ROOT") or os.path.join(HOME, "claude-reports")).rstrip("/"),
    "skill-updates")
DEADLINE = time.monotonic() + float(os.environ.get("SKILL_UPDATES_DEADLINE") or "8")
TODAY = os.environ.get("SKILL_UPDATES_TODAY") or time.strftime("%Y-%m-%d")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SUMMARY_MAX = 5


class Failed(Exception):
    pass


def remaining():
    r = DEADLINE - time.monotonic()
    if r <= 0.2:
        raise Failed("打ち切りの時間を過ぎた")
    return r


def api_command(path):
    custom = os.environ.get("SKILL_UPDATES_API")
    if custom:
        return [custom, path]
    # gh はログイン済みのときだけ使う。未ログインの gh api は失敗するため、そのときは curl で認証なしに読む。
    if shutil.which("gh") and subprocess.run(
            ["gh", "auth", "token"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=remaining()).returncode == 0:
        return ["gh", "api", "-H", "Accept: application/vnd.github+json", path]
    return ["curl", "-fsSL", "--max-time", str(int(remaining()) or 1),
            "-H", "Accept: application/vnd.github+json", "https://api.github.com/" + path]


def api(path):
    try:
        p = subprocess.run(api_command(path), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=remaining())
    except subprocess.TimeoutExpired:
        raise Failed("GitHub API の応答が打ち切りの時間内に返らなかった: " + path)
    if p.returncode != 0:
        raise Failed("GitHub API を読めなかった（終了コード %d）: %s" % (p.returncode, path))
    try:
        return json.loads(p.stdout.decode("utf-8"))
    except ValueError:
        raise Failed("GitHub API の応答が JSON ではない: " + path)


def git_blob_sha(path):
    with open(path, "rb") as f:
        data = f.read()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def local_tree(root):
    """スキルの実体の各ファイルを {相対パス: blob の SHA} にする。名前が . で始まるものは除く。"""
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        for name in files:
            if name.startswith("."):
                continue
            full = os.path.join(d, name)
            out[os.path.relpath(full, root)] = git_blob_sha(full)
    return out


def upstream_tree(source, commit, skill_dir):
    t = api("repos/%s/git/trees/%s?recursive=1" % (source, commit))
    if not isinstance(t, dict) or t.get("truncated"):
        raise Failed("上流のファイルの一覧を取りきれなかった: " + source)
    prefix = skill_dir + "/" if skill_dir else ""
    out = {}
    for e in t.get("tree", []):
        p = e.get("path", "")
        if e.get("type") != "blob" or not p.startswith(prefix):
            continue
        rel = p[len(prefix):]
        if any(part.startswith(".") for part in rel.split("/")):
            continue
        out[rel] = e.get("sha")
    return out


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def check_skill(name, entry, state):
    """新しい版があれば {name, source, summary} を返す。無ければ None。state を更新する。"""
    source = entry.get("source", "")
    skill_dir = os.path.dirname(entry.get("skillPath", ""))
    q = urllib.parse.urlencode({"path": skill_dir, "per_page": 20}) if skill_dir else "per_page=20"
    commits = api("repos/%s/commits?%s" % (source, q))
    if not isinstance(commits, list) or not commits:
        raise Failed("上流のコミットを読めなかった: " + source)
    latest = commits[0].get("sha")
    rec = state.setdefault(name, {})
    rec["latest_seen"] = latest
    if rec.get("installed") == latest:
        return None
    # 記録が無い・記録と違うときは、中身で比べる。更新した後は中身が一致するため、ここで記録が進む。
    local = os.path.join(SKILLS_DIR, name)
    if os.path.isdir(local) and local_tree(local) == upstream_tree(source, latest, skill_dir):
        rec["installed"] = latest
        rec.pop("summary", None)
        return None
    subjects = []
    for c in commits:
        if c.get("sha") == rec.get("installed"):
            break
        msg = ((c.get("commit") or {}).get("message") or "").splitlines()
        subjects.append(msg[0].strip() if msg else "")
    subjects = [s for s in subjects if s]
    more = len(subjects) - SUMMARY_MAX
    summary = "、".join(subjects[:SUMMARY_MAX]) or "（コミットの件名なし）"
    if more > 0:
        summary += " ほか %d 件" % more
    if not rec.get("installed"):
        summary += "（手元の版の記録が無いため、上流の最近のコミットを示す）"
    rec["summary"] = summary
    return {"name": name, "source": source, "summary": summary}


def main():
    lock = load_json(LOCK, None)
    if not isinstance(lock, dict) or not isinstance(lock.get("skills"), dict):
        raise Failed("ロックファイルを読めなかった: " + LOCK)
    state = load_json(STATE_FILE, {})
    if not isinstance(state, dict):
        state = {}
    found = []
    try:
        for name in sorted(lock["skills"]):
            entry = lock["skills"][name]
            if isinstance(entry, dict) and entry.get("sourceType") == "github" and entry.get("source"):
                r = check_skill(name, entry, state)
                if r:
                    found.append(r)
    finally:
        write_atomic(STATE_FILE, json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    if not found:
        return
    lines = ["- `%s`（%s）: %s" % (f["name"], f["source"], f["summary"]) for f in found]
    report = "\n".join([
        "# 外部スキルの新しい版（%s）" % TODAY, "",
        "上流に新しい版が出ている外部スキルの一覧である。自動では更新していない。", "",
        *lines, "",
        "対応するときの手順は Skill `skill-updates` に従う。", ""])
    write_atomic(os.path.join(REPORTS_DIR, TODAY + ".md"), report)
    context = "\n".join([
        "外部スキルに上流の新しい版がある（Skill skill-updates の確認。%s）。" % TODAY,
        *lines,
        "最初の返答で、対象のスキル名と概要を列挙し、今対応するかを利用者に問う。"
        "更新は自動では行わない。対応するときの手順は Skill skill-updates に従う。"])
    names = "・".join(f["name"] for f in found)
    print(json.dumps({
        "systemMessage": "外部スキルの新しい版: %s" % names,
        "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context},
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Failed as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
    except (OSError, subprocess.SubprocessError) as e:
        print("確認できなかった: %s" % e, file=sys.stderr)
        sys.exit(1)
