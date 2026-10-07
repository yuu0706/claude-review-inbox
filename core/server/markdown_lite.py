"""Markdown を HTML に整形する小さな部品。Python 3.9 の標準ライブラリだけで動く。

入力はすべて外から入った文字列として扱い、生の HTML は通さない（すべてエスケープする）。
完全な CommonMark ではない。スキルの本文が崩れずに読めることを優先する。

使い方:
  render(text, link=None)
    link は相対パスのリンクの先を受け取り、書き換えた href を返す関数。None を返すと文字のまま出す。
    link を渡さないときは、相対パスのリンクをすべて文字のまま出す。
"""

import html
import re

FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*#*[ \t]*$")
HR_RE = re.compile(r"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
QUOTE_RE = re.compile(r"^ {0,3}> ?(.*)$")
ITEM_RE = re.compile(r"^([ \t]*)([-*+]|\d{1,9}[.)])(?:[ \t]+(.*))?$")
TABLE_SEP_RE = re.compile(r"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$")
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")

# 行内の要素。先に現れたものから順に解釈する。
INLINE_RE = re.compile(
    r"(?P<code>(?P<tick>`+)(?P<code_body>.+?)(?<!`)(?P=tick)(?!`))"
    r"|(?P<image>!\[(?P<image_alt>[^\]]*)\]\((?P<image_url>[^)\s]*)(?:\s+\"[^\"]*\")?\))"
    r"|(?P<link>\[(?P<link_text>[^\]]+)\]\((?P<link_url>[^)\s]*)(?:\s+\"[^\"]*\")?\))"
    r"|(?P<strong>(?P<sm>\*\*|__)(?P<strong_body>\S(?:.*?\S)?)(?P=sm))"
    r"|(?P<em>(?<![A-Za-z0-9_*])(?P<emm>\*|_)(?P<em_body>[^\s*_](?:[^*_]*?[^\s*_])?)(?P=emm)(?![A-Za-z0-9_*]))"
)


def esc(v):
    return html.escape(str(v), quote=True)


def expand_tabs(line):
    return line.expandtabs(4)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def inline(text, link=None):
    """行内の要素（コード・画像・リンク・太字・強調）を整形する。それ以外の文字はエスケープする。"""
    out = []
    pos = 0
    for m in INLINE_RE.finditer(text):
        out.append(esc(text[pos:m.start()]))
        pos = m.end()
        if m.group("code"):
            out.append("<code>%s</code>" % esc(m.group("code_body").strip(" ") or m.group("code_body")))
        elif m.group("image"):
            # 画像は表示しない。代わりの文字を文字として出す。
            out.append(esc(m.group("image_alt")))
        elif m.group("link"):
            out.append(render_link(m.group("link_text"), m.group("link_url"), m.group(0), link))
        elif m.group("strong"):
            out.append("<strong>%s</strong>" % inline(m.group("strong_body"), link))
        else:
            out.append("<em>%s</em>" % inline(m.group("em_body"), link))
    out.append(esc(text[pos:]))
    return "".join(out)


def render_link(label, url, source, link):
    """リンク1件。許可する形の先だけを a にし、それ以外は元の文字のまま出す。"""
    inner = inline(label, None)
    low = url.lower()
    if low.startswith("http:") or low.startswith("https:"):
        return '<a href="%s" rel="noopener noreferrer">%s</a>' % (esc(url), inner)
    if url.startswith("#"):
        return '<a href="%s">%s</a>' % (esc(url), inner)
    if url and not SCHEME_RE.match(url) and not url.startswith("/") and not url.startswith("\\") and link:
        href = link(url)
        if href:
            return '<a href="%s">%s</a>' % (esc(href), inner)
    return esc(source)


def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    cells = re.split(r"(?<!\\)\|", s)
    return [c.strip().replace("\\|", "|") for c in cells]


def is_table_start(lines, i):
    return ("|" in lines[i] and i + 1 < len(lines) and "-" in lines[i + 1]
            and TABLE_SEP_RE.match(lines[i + 1]) is not None and "|" in lines[i + 1])


def starts_block(lines, i):
    """段落を打ち切る行か。"""
    line = lines[i]
    return bool(FENCE_RE.match(line) or HEADING_RE.match(line) or HR_RE.match(line) or QUOTE_RE.match(line)
                or ITEM_RE.match(line) and indent_of(line) < 4 or is_table_start(lines, i))


def render(text, link=None):
    """Markdown の文字列を HTML の断片にする。"""
    lines = [expand_tabs(l) for l in str(text).replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    return "\n".join(blocks(lines, link))


def blocks(lines, link):
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = FENCE_RE.match(line)
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            mark = m.group(1)
            closing = re.compile(r"^ {0,3}%s{%d,}[ \t]*$" % (re.escape(mark[0]), len(mark)))
            body = []
            i += 1
            while i < n and not closing.match(lines[i]):
                body.append(lines[i])
                i += 1
            i += 1
            # 言語名は class に入れない。中身は整形しない。
            out.append("<pre><code>%s</code></pre>" % esc("\n".join(body)))
            continue
        m = HEADING_RE.match(line)
        if m:
            level = len(m.group(1))
            out.append("<h%d>%s</h%d>" % (level, inline(m.group(2) or "", link), level))
            i += 1
            continue
        if HR_RE.match(line):
            out.append("<hr>")
            i += 1
            continue
        if QUOTE_RE.match(line):
            inner = []
            while i < n and lines[i].strip():
                q = QUOTE_RE.match(lines[i])
                inner.append(q.group(1) if q else lines[i])
                i += 1
            out.append("<blockquote>\n%s\n</blockquote>" % "\n".join(blocks(inner, link)))
            continue
        if is_table_start(lines, i):
            head = split_row(lines[i])
            i += 2
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(split_row(lines[i]))
                i += 1
            width = len(head)
            parts = ['<div class="md-table"><table>', "<thead><tr>"]
            parts.extend("<th>%s</th>" % inline(c, link) for c in head)
            parts.append("</tr></thead>")
            if rows:
                parts.append("<tbody>")
                for r in rows:
                    r = (r + [""] * width)[:width]
                    parts.append("<tr>%s</tr>" % "".join("<td>%s</td>" % inline(c, link) for c in r))
                parts.append("</tbody>")
            parts.append("</table></div>")
            out.append("".join(parts))
            continue
        if ITEM_RE.match(line) and indent_of(line) < 4:
            ordered = ITEM_RE.match(line).group(2)[0].isdigit()
            j = i + 1
            while j < n:
                other = ITEM_RE.match(lines[j])
                if other and indent_of(lines[j]) <= indent_of(line) and other.group(2)[0].isdigit() != ordered:
                    # 同じ深さで番号の有無が変わったら、別の箇条書きとする。
                    break
                if lines[j].strip():
                    if indent_of(lines[j]) > indent_of(line) or ITEM_RE.match(lines[j]):
                        j += 1
                        continue
                    # 字下げの無い続きの行は、直前が空行でなければ項目の続きとして扱う。
                    if lines[j - 1].strip() and not starts_block(lines, j):
                        j += 1
                        continue
                    break
                # 空行の後に、字下げした行か項目が続くなら箇条書きの中とする。
                k = j
                while k < n and not lines[k].strip():
                    k += 1
                if k < n and (indent_of(lines[k]) > indent_of(line) or ITEM_RE.match(lines[k])
                              and indent_of(lines[k]) >= indent_of(line)):
                    j = k
                    continue
                break
            out.append(render_list(lines[i:j], link))
            i = j
            continue
        para = [line.strip()]
        i += 1
        while i < n and lines[i].strip() and not starts_block(lines, i):
            para.append(lines[i].strip())
            i += 1
        out.append("<p>%s</p>" % inline(" ".join(para), link))
    return out


def render_list(lines, link):
    """箇条書きの塊を ul・ol にする。最初の項目と同じ字下げの項目を並べ、より深い行は項目の中身とする。"""
    first = ITEM_RE.match(lines[0])
    base = indent_of(lines[0])
    ordered = first.group(2)[0].isdigit()
    items = []
    for line in lines:
        m = ITEM_RE.match(line)
        if m and indent_of(line) <= base and (m.group(2)[0].isdigit()) == ordered:
            items.append({"text": [m.group(3) or ""], "rest": [], "pad": len(m.group(1)) + len(m.group(2)) + 1})
        elif not items:
            continue
        elif items[-1]["rest"] or not line.strip() or m:
            # 空行の後・入れ子の項目の後は、項目の中のブロックとして扱う。
            items[-1]["rest"].append(line)
        else:
            # 項目の1行目の続き（字下げの有無を問わない）。
            items[-1]["text"].append(line.strip())
    tag = "ol" if ordered else "ul"
    start = ""
    if ordered:
        num = int(re.match(r"\d+", first.group(2)).group(0))
        if num != 1:
            start = ' start="%d"' % num
    out = ["<%s%s>" % (tag, start)]
    for it in items:
        rest = it["rest"]
        while rest and not rest[-1].strip():
            rest.pop()
        body = inline(" ".join(t for t in it["text"] if t), link)
        if rest:
            shift = min(indent_of(l) for l in rest if l.strip())
            body += "\n" + "\n".join(blocks([l[shift:] if l.strip() else "" for l in rest], link))
        out.append("<li>%s</li>" % body)
    out.append("</%s>" % tag)
    return "\n".join(out)
