"""会話の履歴（jsonl）から、利用者本人の発言だけを取り出す（feedback-mining の検問所）。

使い方: python3 -B extract-user.py <一覧のファイル> <出力先のフォルダ>
  一覧のファイルには jsonl の絶対パスを1行1件で書く。
  出力先のフォルダに、入力ごとに <連番4桁>.md を書き、取り出したファイルの一覧を標準出力へ1行1件で出す。
  発言が1件も残らなかった入力はファイルを作らない。

除くもの:
  - type が user でない行（assistant・system・summary など）
  - isMeta・isCompactSummary・isVisibleInTranscriptOnly が真の行、toolUseResult を持つ行
  - ツールの結果（content に tool_result を含む行）
  - スラッシュコマンドの展開とその出力（<command-name> 等・<local-command-stdout> を含む行）
  - フックの出力（<system-reminder>…</system-reminder> などの区画）
  - 貼り付けた文章の中身（<pasted_content …>…</pasted_content> は「（貼り付けあり）」だけを残す）

Python 3.9 の標準ライブラリだけで動く。claude には元の jsonl を読ませず、このスクリプトの出力だけを渡す。
"""

import json
import os
import re
import sys

PASTED_RE = re.compile(r"<pasted_content\b[^>]*>.*?(</pasted_content>|\Z)", re.S)
# フックや Claude Code が利用者の発言に差し込む区画。中身ごと除く。
INJECTED_TAGS = ("system-reminder", "user-prompt-submit-hook", "hook-output", "session-start-hook")
INJECTED_RE = re.compile(r"<(%s)\b[^>]*>.*?(</\1>|\Z)" % "|".join(INJECTED_TAGS), re.S)
# スラッシュコマンドの展開とローカルのコマンドの出力。行ごと除く。
COMMAND_MARKS = ("<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>",
                 "<local-command-stderr>", "<local-command-caveat>")
PASTED_NOTE = "（貼り付けあり）"


def message_text(rec):
    """利用者本人の発言の本文を返す。除く行なら None を返す。"""
    if rec.get("type") != "user":
        return None
    for key in ("isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"):
        if rec.get(key):
            return None
    if "toolUseResult" in rec:
        return None
    msg = rec.get("message")
    if not isinstance(msg, dict) or msg.get("role", "user") != "user":
        return None
    content = msg.get("content")
    if isinstance(content, str):
        parts = [content]
    elif isinstance(content, list):
        parts = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "tool_result":
                return None
            if item.get("type") == "text" and isinstance(item.get("text"), str):
                parts.append(item["text"])
    else:
        return None
    text = "\n".join(parts)
    if any(m in text for m in COMMAND_MARKS):
        return None
    text = PASTED_RE.sub(PASTED_NOTE, text)
    text = INJECTED_RE.sub("", text)
    text = text.strip()
    return text or None


def extract(path):
    """1つの jsonl から（日時, 本文）の並びを返す。読めない行は飛ばす。"""
    out = []
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            text = message_text(rec)
            if text is not None:
                out.append((str(rec.get("timestamp") or ""), text))
    return out


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("使い方: extract-user.py <一覧のファイル> <出力先のフォルダ>\n")
        return 2
    list_file, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    with open(list_file, encoding="utf-8") as f:
        inputs = [ln.rstrip("\n") for ln in f if ln.strip()]
    n = 0
    for src in inputs:
        msgs = extract(src)
        if not msgs:
            continue
        n += 1
        dest = os.path.join(out_dir, "%04d.md" % n)
        with open(dest, "w", encoding="utf-8") as w:
            w.write("# 利用者の発言（元の会話: %s）\n\n" % src)
            for ts, text in msgs:
                w.write("## %s\n\n%s\n\n" % (ts or "日時不明", text))
        print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
