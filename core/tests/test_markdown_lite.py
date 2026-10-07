"""markdown_lite.py の検査。各要素の整形と、生の HTML・危険なリンクがエスケープされることを確かめる。"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))
import markdown_lite as md  # noqa: E402


def rewrite(url):
    """検査用の書き換え。.md で終わる相対パスだけを /skills/sample/ の下へ向ける。"""
    return "/skills/sample/" + url if url.endswith(".md") else None


class MarkdownLiteTest(unittest.TestCase):
    def test_headings(self):
        out = md.render("# 見出し1\n## 見出し2\n###### 見出し6")
        self.assertIn("<h1>見出し1</h1>", out)
        self.assertIn("<h2>見出し2</h2>", out)
        self.assertIn("<h6>見出し6</h6>", out)
        self.assertNotIn("id=", out)

    def test_paragraph_joins_lines(self):
        out = md.render("一行目\n二行目\n\n次の段落")
        self.assertIn("<p>一行目 二行目</p>", out)
        self.assertIn("<p>次の段落</p>", out)

    def test_inline(self):
        out = md.render("**太字** と *強調* と `<code>` と [外部](https://example.com/a?b=1&c=2) と [節](#top)")
        self.assertIn("<strong>太字</strong>", out)
        self.assertIn("<em>強調</em>", out)
        self.assertIn("<code>&lt;code&gt;</code>", out)
        self.assertIn('<a href="https://example.com/a?b=1&amp;c=2" rel="noopener noreferrer">外部</a>', out)
        self.assertIn('<a href="#top">節</a>', out)

    def test_code_span_is_not_formatted(self):
        out = md.render("`**そのまま**`")
        self.assertIn("<code>**そのまま**</code>", out)

    def test_snake_case_is_not_emphasis(self):
        out = md.render("CLAUDE_SKILLS_DIR と a_b_c")
        self.assertNotIn("<em>", out)

    def test_raw_html_is_escaped(self):
        out = md.render('<script>alert(1)</script>\n\n# <img src=x onerror=alert(1)>\n\n| <b>x</b> | y |\n|---|---|\n| <i>z</i> | w |')
        self.assertNotIn("<script>", out)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", out)
        self.assertNotIn("<img", out)
        self.assertNotIn("<b>", out)
        self.assertNotIn("<i>", out)

    def test_dangerous_links_stay_text(self):
        out = md.render('[押す](javascript:alert(1)) [データ](data:text/html,x) [絶対](/etc/passwd) [ファイル](file:///etc/hosts)')
        self.assertNotIn("<a", out)
        self.assertIn("[押す](javascript:alert(1))", out)
        self.assertIn("[絶対](/etc/passwd)", out)

    def test_attribute_injection_is_escaped(self):
        out = md.render('[x](https://example.com/"onmouseover="alert(1))')
        self.assertNotIn('"onmouseover="', out)

    def test_relative_links(self):
        out = md.render("[参照](references/a.md) [画像](img/a.txt)", link=rewrite)
        self.assertIn('<a href="/skills/sample/references/a.md">参照</a>', out)
        self.assertIn("[画像](img/a.txt)", out)
        self.assertEqual(md.render("[参照](a.md)").count("<a"), 0)

    def test_image_shows_alt_text(self):
        out = md.render("![代わりの文字](https://example.com/a.png)")
        self.assertNotIn("<img", out)
        self.assertIn("代わりの文字", out)
        self.assertNotIn("example.com", out)

    def test_nested_lists(self):
        out = md.render("- 一\n  - 一の一\n    - 一の一の一\n- 二\n\n1. 甲\n2. 乙\n")
        self.assertIn("<ul>\n<li>一\n<ul>\n<li>一の一\n<ul>\n<li>一の一の一</li>\n</ul></li>\n</ul></li>\n<li>二</li>\n</ul>", out)
        self.assertIn("<ol>\n<li>甲</li>\n<li>乙</li>\n</ol>", out)

    def test_list_type_change(self):
        out = md.render("- 一\n1. 甲")
        self.assertIn("<ul>\n<li>一</li>\n</ul>", out)
        self.assertIn("<ol>\n<li>甲</li>\n</ol>", out)

    def test_list_item_continuation(self):
        out = md.render("- 一行目\n  続き\n- 二")
        self.assertIn("<li>一行目 続き</li>", out)

    def test_table(self):
        out = md.render("| 名前 | 説明 |\n| --- | :---: |\n| `a\\|b` | **太字** |\n| 欠け |")
        self.assertIn('<div class="md-table"><table><thead><tr><th>名前</th><th>説明</th></tr></thead>', out)
        self.assertIn("<td><code>a|b</code></td><td><strong>太字</strong></td>", out)
        self.assertIn("<td>欠け</td><td></td>", out)

    def test_fenced_code_is_not_formatted(self):
        out = md.render("```bash\n# 見出しではない\n**太字ではない** <b>\n- 箇条書きではない\n```\n~~~\n[x](https://e)\n~~~")
        self.assertIn("<pre><code># 見出しではない\n**太字ではない** &lt;b&gt;\n- 箇条書きではない</code></pre>", out)
        self.assertIn("<pre><code>[x](https://e)</code></pre>", out)
        self.assertNotIn("class=", out.replace('class="md-table"', ""))
        self.assertNotIn("<h1>", out)

    def test_unclosed_fence(self):
        out = md.render("```\n<script>\n")
        self.assertIn("<pre><code>&lt;script&gt;\n</code></pre>", out)

    def test_blockquote(self):
        out = md.render("> 引用の\n> **文**")
        self.assertIn("<blockquote>\n<p>引用の <strong>文</strong></p>\n</blockquote>", out)

    def test_hr(self):
        out = md.render("前\n\n---\n\n***\n\n後")
        self.assertEqual(out.count("<hr>"), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
