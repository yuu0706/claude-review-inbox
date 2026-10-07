#!/usr/bin/env python3
"""メモリの索引（MEMORY.md）のうち、指定したメモリのファイルを指す行を扱う。

ファイルの削除と、そのファイルを指す索引の行の削除を1件の案にまとめるために、定期実行のスクリプトが使う。
索引の行は「(<ファイル名>)」を含む行とする（例: `- [題](foo.md) — 説明`）。

使い方:
  memory-index.py drop <MEMORY.md> <ファイル名>...
      指定したファイルを指す行を除いた内容を標準出力へ出す。
  memory-index.py keep <元の MEMORY.md> <直した版の MEMORY.md> <ファイル名>...
      直した版で消された行のうち、指定したファイルを指す行を元の位置へ戻した内容を標準出力へ出す。
      索引の行の削除をメモリの削除の案へ移し、索引だけの案を別に作らないために使う。
"""
import difflib
import sys


def refers(line, names):
    return any("(" + n + ")" in line for n in names)


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines(keepends=True)


def drop(path, names):
    return [l for l in read_lines(path) if not refers(l, names)]


def keep(orig_path, staged_path, names):
    orig = read_lines(orig_path)
    staged = read_lines(staged_path)
    out = []
    sm = difflib.SequenceMatcher(a=orig, b=staged, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("delete", "replace"):
            out.extend(l for l in orig[i1:i2] if refers(l, names))
        if tag != "delete":
            out.extend(staged[j1:j2])
    return out


def main(argv):
    if len(argv) >= 3 and argv[0] == "drop":
        lines = drop(argv[1], argv[2:])
    elif len(argv) >= 4 and argv[0] == "keep":
        lines = keep(argv[1], argv[2], argv[3:])
    else:
        sys.stderr.write(__doc__)
        return 2
    sys.stdout.write("".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
