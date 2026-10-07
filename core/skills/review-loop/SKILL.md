---
name: review-loop
description: 週1回の棚卸し（スキルとメモリの改善案づくり）の結果を読む・手で動かす・止めるときに使う。install.sh で棚卸しを入れると、launchd が毎週 scripts/run.sh を起動し、claude -p が自作のスキルとメモリを読んで改善案を作る。追加だけの変更はその場で反映し、修正と削除は Skill change-review の承認待ちにする。「棚卸しの結果を見て」「棚卸しを今すぐ動かして」「棚卸しを止めたい」「棚卸しの時刻やモデルを変えたい」と言われたときに使う。
---

# review-loop（週1回の棚卸し）

## 1. 何をするか

`scripts/run.sh` が次の順に動く。`claude` に元のスキル・メモリ・案・台帳を直接書かせない。

1. 対象を決める。スキルは `~/.claude/skills`（あれば `~/.claude2/skills`）のうち自作のもの、メモリは `~/.claude/projects/*/memory`（あれば `~/.claude2/projects/*/memory`）である。シンボリックリンクのスキル（他から導入したもの・本リポジトリのスキル）と `.trash` は除く。
2. 前回の実行から対象が変わっていなければ、起動せずに終わる。
3. 対象を `~/.local/state/claude-review-inbox/review-loop/runs/<日時>/before` へ複製する。
4. `claude -p` を起動し、直した版を作業用のフォルダ（同じ `runs/<日時>/stage`）へ書かせる。
5. 正常終了したら、シェルがファイルごとに差分を取る。既存の行を変えない・消さない変更は元の場所へ書き戻す。それ以外の修正・新しいファイル・削除の候補は、Skill `change-review` の承認待ちの案にする。1回あたりの変更は5件までである。
   修正と削除の案には、claude が作業用のフォルダの `destinations/` の下に書いた「消える記述の行き先」の表と、移し先への追加の差分を入れる（Skill `change-review` の「2.2」）。移し先への追加は自動では反映しない。メモリの削除の案には、そのメモリを指す索引（`MEMORY.md`）の行の削除も入れ、索引だけの案は作らない。
6. 結果を `~/claude-reports/review-loop/<YYYY-MM-DD>.md` に書く。

依頼文には、否認リスト（`~/claude-reports/proposals/rejections.md`）を読むこと、`pending` の案と同じ変更を作らないこと、個人情報について推測にもとづく変更を作らないことを含めている。

## 2. 操作

| 操作 | コマンド |
| --- | --- |
| 組み立てたコマンドを確かめる（何も変えない） | `scripts/run.sh --dry-run` |
| 今すぐ動かす（対象が変わっていなくても動かす） | `scripts/run.sh --force` |
| 結果を読む | `~/claude-reports/review-loop/` の最新のファイルを開く |
| ログを読む | `~/.local/state/claude-review-inbox/review-loop/logs/` |
| 止める | リポジトリの `install.sh --no-schedule` を実行する |

## 3. 設定

時刻とモデルは、`install.sh` を実行するときの環境変数で決まる（plist に書き込む）。変えるときは、環境変数を付けて `install.sh --with-schedule` を実行し直す。

| 環境変数 | 意味 | 既定 |
| --- | --- | --- |
| `CLAUDE_REVIEW_LOOP_WEEKDAY` | 曜日（0 と 7 が日曜、1 が月曜） | 1 |
| `CLAUDE_REVIEW_LOOP_HOUR` | 時 | 10 |
| `CLAUDE_REVIEW_LOOP_MINUTE` | 分 | 0 |
| `CLAUDE_REVIEW_LOOP_MODEL` | `claude` に渡す `--model` | 付けない（利用者の既定に従う） |
| `CLAUDE_REVIEW_LOOP_EFFORT` | `claude` に渡す `--effort` | 付けない |

棚卸しは利用者の Claude の利用枠を使う。
