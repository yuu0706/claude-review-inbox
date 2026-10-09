---
name: report-inbox
description: 定期実行のジョブ（repo-patrol・feedback-mining・memory-audit・secret-patrol）が ~/claude-reports/ に書いた結果と、5つのジョブ（skill-audit を含む）の失敗の知らせを一覧にし、開き、既読にするときに使う。会話の開始時に「未読の結果」が表示されたとき、「結果を見せて」「未読の結果は？」「レポートを見て」と言われたときに使う。各ジョブの結果の読み方は、ジョブごとのスキルに従う。
---

# 定期実行の結果の受け取り

定期実行のジョブは、結果を `~/claude-reports/<ジョブ名>/<YYYY-MM-DD>.md` に Markdown で書く。

利用者の環境だけの決まり（結果の閲覧ツール・呼び名など）は、上書きファイル `${XDG_CONFIG_HOME:-~/.config}/claude-skills/report-inbox.local.md` に書く。あれば最初に読み、本文と食い違う箇所は上書きファイルに従う。

| ジョブ | 時刻（既定） | 結果の読み方 |
| --- | --- | --- |
| `repo-patrol` | 会話の開始時（1日1回。SessionStart の hook） | Skill `repo-patrol` |
| `memory-audit` | 月曜 10:30 | Skill `memory-audit` |
| `feedback-mining` | 月曜 11:00 | Skill `feedback-mining` |
| `secret-patrol` | 会話の開始時（7日ごと。SessionStart の hook） | Skill `secret-patrol` |

`skill-audit`（月曜 10:00）は精査の記録を `${SKILL_AUDIT_STATE:-~/.local/state/skill-audit}/history.md` に書く。精査は報告しない決まりのため記録は扱わないが、失敗は他のジョブと同じく知らせる。
公開版の点検で当たりなどがあった場合だけ、`skill-audit` は結果を `~/claude-reports/skill-audit/<YYYY-MM-DD>.md` に書く。読み方は Skill `skill-audit` の「2.8 公開版の点検」に従う。
週1回の3つのジョブ（`memory-audit`・`feedback-mining`・`skill-audit`）は、`install.sh` で登録したときだけ動く。

## 1. 未読の知らせ

会話の開始時に、SessionStart フックが `scripts/unread.sh` を動かし、未読があれば「未読の結果: …」と1行だけ表示する。
承認待ちと承認済み・未反映の案があれば、同じ行の先頭に「承認待ち N件（<最も古い番号>〜）・承認済み・未反映 N件」を載せる（0件の項目は出さない）。
表示されても、利用者が頼むまで結果を読みに行かない。表示を見て利用者が頼んだら「2.」へ進む。

## 2. 結果を読む

1. `scripts/list.sh --unread` で未読の一覧を出す。
2. 利用者が選んだ結果（指定が無ければ未読の全部）を、ジョブごとのスキルの手順で読んで伝える。
3. 伝え終えたら `scripts/mark-read.sh <パス...>` で既読にする。全部まとめて既読にするときは `--all`。

利用者は承認の画面（既定 `http://127.0.0.1:8010/`）の上のトグルで「レポート」に切り替え、レポートを読んで既読にすることもできる（同じ `read.txt` に記録される）。

## 2.1 承認待ち

承認待ち（`~/claude-reports/proposals/`）は定期実行の結果ではない。既読にせず、Skill `change-review` の手順で読む・反映する。
利用者は画面（既定 `http://127.0.0.1:8010/`）で承認・保留・却下できる。「承認済み・未反映」は画面で承認されたもので、利用者が会話で「承認分を反映して」と言ったときに `change-review` の手順で反映する。
件数は `change-review` の `scripts/count.sh` が数える。`unread.sh` はスキル置き場の `change-review` を経由してこれを呼ぶ。

## 3. 置き場所

- 結果: `~/claude-reports/`（`memory-audit/.snapshots/` と `.staging/` はメモリの複製と作業用であり、結果ではない）
- 既読の記録とログ: `~/.local/state/claude-reports/`
