---
name: repo-patrol
description: 手元のリポジトリを置いているフォルダ（install.sh で指定。例 ~/Documents/git）の下のローカルリポジトリを見回り、コミットしていない変更・push していないコミット・stash・マージ済みで残っているブランチを一覧にした結果を読むときに使う。Claude Code の SessionStart の hook から、その日の最初のセッションで裏で結果を作る（claude は使わない）。「リポジトリの見回りの結果を見て」「push し忘れはある？」「片付けられるブランチは？」等のときに使う。結果の置き場所と既読の管理は Skill `report-inbox` に従う。
---

# ローカルリポジトリの見回り

`scripts/patrol.sh` が、見回りの対象のフォルダの直下と1段下にあるリポジトリを読み取りだけで調べ、結果を `~/claude-reports/repo-patrol/<日付>.md` に書く。

対象のフォルダは、`install.sh` が聞いて設定ファイル `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/patrol.conf` の `REPO_ROOTS` に書く（先頭の1つを使う）。環境変数 `REPO_PATROL_ROOT` があれば、そちらを使う。どちらも無ければ見回らない。

利用者の環境だけの決まり（呼び名・push の決まりの出典など）は、上書きファイル `${XDG_CONFIG_HOME:-~/.config}/claude-skills/repo-patrol.local.md` に書く。あれば最初に読み、本文と食い違う箇所は上書きファイルに従う。

## 1. 見ているもの

- 現在のブランチ、コミットしていない変更（staged / unstaged / untracked）、stash の件数
- 上流ブランチと比べた ahead / behind、push していないコミットがあるブランチ
- 既定ブランチへマージ済みで、現在のブランチ以外のローカルブランチ
- 最後に追跡ブランチを取得した日時

`git fetch` はしない。ahead / behind は、手元に残っている前回の取得結果と比べた値である。
最後の取得が古いリポジトリでは、実際のリモートとずれている可能性がある。

## 2. 結果を読む依頼への対応

1. Skill `report-inbox` の手順で、最新の結果を開く。
2. 冒頭に「読めなかった」「失敗」「警告」の行があれば、最初に伝える。
   対象のフォルダを読めなかった結果は、0件でも「問題なし」ではない（launchd の下では、macOS のプライバシー保護（TCC）により `~/Documents` などを読めない）。
   読めなかったときは終了コード1で終わり、`report-inbox` の失敗の知らせにも出る。対処はその時点で利用者と決める。
   hook からの起動では、読めなければ実行自体を見送るため、通常この行は出ない。
3. 「対応が要るもの」から順に要約して伝える。
4. push・ブランチの削除・stash の破棄は、**結果を見たというだけでは行わない。**
   利用者が対象を指定して頼んだときだけ行う。
   ブランチの削除は、マージ済みであることを `git branch --merged` で改めて確かめてから行う。
5. 読み終えたら、`report-inbox` の手順で既読にする。

## 3. 運用

- 起動は SessionStart の hook の `scripts/run-if-due.sh` が行う。今日の結果がまだ無く、対象のフォルダを一覧できるときだけ、`patrol.sh` を裏で1回動かす。土日も動く。
- 一覧できないとき（launchd などから起動した `claude -p` で hook が走った場合など）は何もせずに終わり、次のセッションに持ち越す。見送ったことは `~/.local/state/claude-reports/repo-patrol/skipped.log` に1行残る。
- launchd では起動しない。launchd から起動した `/bin/bash` は TCC により `~/Documents` などを一覧できないためである。launchd の plist は持たない。
- hook は `install.sh` が登録する。手動での登録と実行の方法は `scripts/README.md` に書いてある。
