---
name: secret-patrol
description: 秘密情報と個人情報の置き忘れを週1回見回った結果を読むときに使う。Claude 自身の記録（メモリ・スキル・CLAUDE.md・settings.json）と手元のリポジトリ（作業ツリーと push していないコミット）の秘密を gitleaks で、Downloads・Desktop・Documents（install.sh で許可したときだけ）とリポジトリに残った個人情報らしきファイルを件数で、permissions.deny と秘密の検査の hook が外れていないかを調べる。Claude Code の会話を始めたとき、前回から7日たっていれば SessionStart フックが裏で結果を作る（claude は使わない）。「秘密の見回りの結果を見て」「漏れているものは無い？」「個人情報のファイルが残っていない？」等のときに使う。結果の置き場所と既読の管理は Skill `report-inbox` に従う。
---

# 秘密情報と個人情報の見回り

`scripts/patrol.sh` が読み取りだけで見回り、結果を `~/claude-reports/secret-patrol/<日付>.md` に書く。
規則の取りこぼしを拾うための仕組みである。コミットの直前に止めるのは、各自のコミット前の確認と gitleaks の hook の役目である。

claude を使わない理由: 見回りで見つけた秘密をモデルへ送ると、秘密を会話に出さないという原則に反するためである。結果にも値は書かない。

利用者の環境だけの決まり（秘密の扱いの規則を書いたスキルの名前など）は、上書きファイル `${XDG_CONFIG_HOME:-~/.config}/claude-skills/secret-patrol.local.md` に書く。あれば最初に読み、本文と食い違う箇所は上書きファイルに従う。

## 1. 見ているもの

| 区分 | 対象 | 方法 |
| --- | --- | --- |
| a. Claude 自身の記録 | 各設定ディレクトリ（`CLAUDE_REVIEW_CONFIG_DIRS`。既定は `~/.claude`）のメモリ・スキル・CLAUDE.md・rules・settings.json | gitleaks |
| b. 手元のリポジトリ | 設定ファイル（`patrol.conf`）の `REPO_ROOTS` の各フォルダのリポジトリの作業ツリー、push していないコミット | gitleaks。作業ツリーはコミットされうるファイル（追跡中のものと、無視されていない未追跡のもの）だけを見る。`.gitignore` 済みのもの・入れ子のリポジトリ・シンボリックリンク・`node_modules` などは除く。push 済みの履歴は見ない |
| c. 個人情報の置き忘れ | `~/Downloads`・`~/Desktop`・`~/Documents`（`patrol.conf` の `PERSONAL_FOLDERS=yes` のときだけ）とリポジトリの `.tsv`・`.csv`・`.txt`・`.json` | メールアドレスらしき文字列を含む行が20行以上のファイル。中身は書かず、パスと件数だけ |
| d. 守りの設定 | 各設定ディレクトリの `settings.json` | `permissions.deny` の6つと、秘密の検査の hook（`SECRET_PATROL_HOOK_PATTERN` を含むコマンド。未設定なら確かめない）があるか |

a と b は、前回までに出たものを「既知」として覚え、結果には新しく見つかったものだけを並べる（覚えるのは位置と指紋だけで、値は覚えない）。既知は件数だけを書く。

## 2. 結果を読む依頼への対応

1. Skill `report-inbox` の手順で、最新の結果を開く。
2. 「新規の秘密」「個人情報の置き忘れの候補」「守りの設定」「読めなかった対象」の順に要約して伝える。値は結果にも無く、確かめに行くときも会話へ出さない。
3. 直すかどうかは利用者が決める。結果を見たというだけで直さない。
   - Claude 自身の記録の秘密: 値を消し、置き場所の案内に書き換える案を出す。
   - リポジトリの秘密: 無効化と再発行、Secrets Manager・SSM への移動を案として出す。リポジトリの変更は利用者の指示を待つ。
   - 個人情報のファイル: 消してよいかを1件ずつ確かめる。
4. 読み終えたら、`report-inbox` の手順で既読にする。

## 3. 運用

- 起動は SessionStart フックの `scripts/session-trigger.sh` が行う。前回の起動から7日（`SECRET_PATROL_INTERVAL_DAYS`）たっていれば、`patrol.sh` を裏で1回走らせる。走っている間は CPU を使う。
- フックは `install.sh` が登録する。手動での登録・解除・実行の方法は `scripts/README.md` に書いてある。
- gitleaks が無い、または対象を読めなかったときは、結果を書いたうえで失敗として終わり、`report-inbox` の失敗の知らせに出る。
- launchd で起動しない。launchd から起動すると、`~/Documents`・`~/Downloads`・`~/Desktop` が macOS のプライバシー保護（TCC）により `Operation not permitted` で読めないためである。SessionStart フックはターミナルの権限で動くため読める。
- gitleaks や bash に「フルディスクアクセス」を許可して解決しない。守るための道具が大きな穴になるためである。
- 既知を忘れさせて全件を出し直すときは `patrol.sh --reset-baseline` を使う。
