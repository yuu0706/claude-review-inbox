#!/usr/bin/python3
"""承認済みとして扱ってよい案を判定する。

使い方: approved.py [--paths]
  既定の出力（タブ区切り、1行1件）:
    OK<TAB><案のパス>
    NG<TAB><案のパス><TAB><理由>
  --paths  OK の案のパスだけを1行に1件ずつ出す。

承認済みとして扱うのは、次の3つがそろった案だけである。
  1. ファイルの status が approved
  2. 台帳（decisions.jsonl）でその id の最新の行が to: approved
  3. 台帳の sha256 が、今のファイルの本文（frontmatter を除く）の SHA-256 と一致する
置き場所は環境変数 CLAUDE_REVIEW_PROPOSALS と CLAUDE_REVIEW_STATE で差し替えられる。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import proposal_lib as pl  # noqa: E402


def judge(proposals, decisions):
    ok, ng = [], []
    for p in proposals:
        if p.status != "approved":
            continue
        rec = decisions.get(p.id)
        if rec is None:
            ng.append((p.path, "台帳に記録がない（画面で承認されていない）"))
        elif rec.get("to") != "approved":
            ng.append((p.path, "台帳の最新の判断が approved ではない（%s）" % rec.get("to")))
        elif rec.get("sha256") != p.sha256:
            ng.append((p.path, "承認した後に本文が書き換えられている（SHA-256 が一致しない）"))
        else:
            ok.append(p.path)
    return ok, ng


def main(argv):
    paths_only = False
    for a in argv:
        if a == "--paths":
            paths_only = True
        else:
            sys.stderr.write("不明な引数です: %s\n" % a)
            return 2
    ok, ng = judge(pl.list_proposals(), pl.latest_decisions())
    for path in ok:
        print(path if paths_only else "OK\t%s" % path)
    if not paths_only:
        for path, reason in ng:
            print("NG\t%s\t%s" % (path, reason))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
