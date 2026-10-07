# repo-patrol scripts

見回りの対象のフォルダ（直下と1段下）のローカルリポジトリを巡回し、状態を Markdown のレポートへ書くスクリプトである。claude は使わない。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `patrol.sh [--stdout]` | 巡回してレポートを書く。`--stdout` はファイルへ書かず標準出力へ出す（ログも作らない） |
| `run-if-due.sh` | Claude Code の SessionStart の hook から呼ぶ。今日の結果がまだ無ければ `patrol.sh` を裏で1回動かし、すぐに戻る。何も出力しない |
| `test.sh` | 一時ディレクトリに偽のリポジトリ群を作って `patrol.sh` と `run-if-due.sh` を検査する。ネットワークは使わない |

## 環境変数

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `REPO_PATROL_ROOT` | 設定ファイルの `REPO_ROOTS` の先頭 | 巡回の対象ディレクトリ。設定ファイル（`${CLAUDE_REVIEW_PATROL_CONF:-${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/patrol.conf}`。`install.sh` が書く）にも無ければ見回らない |
| `CLAUDE_REPORTS_ROOT` | `$HOME/claude-reports` | レポートの置き場所。`repo-patrol/<YYYY-MM-DD>.md` に書く |
| `CLAUDE_REPORTS_STATE` | `$HOME/.local/state/claude-reports` | lock とログの置き場所。`repo-patrol/` の下を使う |

## 対象と取得する項目

対象は次のディレクトリである。`.git` がファイルのもの（ワークツリー）も含む。

- `REPO_PATROL_ROOT` 直下で `.git` を持つディレクトリ。その中には入らない。
- `REPO_PATROL_ROOT` 直下で `.git` を持たないディレクトリの、1段下で `.git` を持つディレクトリ（例: `group/repo-a`）。レポートには `REPO_PATROL_ROOT` からの相対パスで載せる。2段下より深いものは見ない。

シンボリックリンクは辿り、リンク先がディレクトリであれば通常のディレクトリと同じに扱う。名前が `.` で始まるものは見ない。

git fetch はしない。ネットワークに触れる git コマンドは使わず、すべて `git --no-optional-locks -C <リポジトリ>` の読み取りで行う。`--no-optional-locks` は、git status が索引（index）を書き直すのを止めるために付けている。

| 項目 | 取得の方法 |
| --- | --- |
| 現在のブランチ | `symbolic-ref --short HEAD`。detached HEAD のときは短いコミット ID を添える |
| コミットしていない変更 | `status --porcelain` を staged・unstaged・untracked に分けて数える |
| stash の件数 | `stash list` の行数 |
| 上流との ahead/behind | `rev-list --left-right --count HEAD...@{u}`。上流が無ければ「上流なし」 |
| push していないコミットがあるローカルブランチ | 各ブランチの上流との差。上流なしのブランチ、上流の参照が消えたブランチも含める |
| マージ済みのブランチ | 既定ブランチへマージ済みで、現在のブランチと既定ブランチ自身を除いたもの |
| 最後に追跡ブランチを取得した日時 | 共通の git ディレクトリにある `FETCH_HEAD` の更新日時。無ければ「不明」 |

既定ブランチは `origin/HEAD` が指すものとする。無ければ `main`・`master`・`develop` の順で、存在する最初のローカルブランチを使う。

ahead/behind と未push の判定は、手元に残っている追跡ブランチの参照で計算する。最後に取得した後に他者が push した分は反映されない。

## レポートの構成

1. 作成日時・対象件数・区分ごとの件数。対象が0件のときは「警告: 対象のリポジトリが0件である」、一覧を読めなかったフォルダがあるときは「失敗: 一覧を読めなかったフォルダがある」を添える。`REPO_PATROL_ROOT` 自体を読めなかったときは、件数の代わりに「読めなかった: <理由>」と書く
2. 対応が要るもの: 変更あり・未push（上流より先行、または未push のブランチあり）・stash ありのリポジトリの表
3. 片付けの候補: マージ済みブランチの表
4. 読めなかったフォルダ: 一覧を読めなかったフォルダと理由の表（該当があるときだけ）
5. 取得失敗: git が失敗したリポジトリと理由の表
6. 問題なし: 上のどれにも当たらないリポジトリ名の一覧

何も無い区分は「該当なし」と書く。1つのリポジトリで git が失敗しても全体は止めず、そのリポジトリを「取得失敗」に入れる。同日に2回目が走った場合は `<YYYY-MM-DD>-2.md` のように連番にする。

## 失敗と警告の扱い

| 状況 | レポート | ログ | 終了コード |
| --- | --- | --- | --- |
| `REPO_PATROL_ROOT` が存在しない | 書かない | `ERROR:` | 1 |
| `REPO_PATROL_ROOT` または1段下のフォルダの一覧を読めない（`ls` が失敗する） | 書く。「読めなかった: <理由>」と「読めなかったフォルダ」の表を載せる | `ERROR:` | 1 |
| 対象のリポジトリが0件 | 書く。「警告: 対象のリポジトリが0件である」を載せる | `WARN:` | 0 |
| リポジトリの git が失敗した | 書く。「取得失敗」に載せる | `ERROR:` | 0 |

一覧を読めるかは `ls` で確かめる。launchd から起動した `/bin/bash` は、macOS の TCC（プライバシー保護）により `~/Documents` 配下の一覧を拒否されることがある（`Operation not permitted`）。このときディレクトリの存在の確認（`[ -d ]`）は通り、glob は展開されずに空振りする。glob の結果だけでは拒否と空のフォルダを区別できないため、先に `ls` で確かめる。

report-inbox は、最新のログの `[YYYY-MM-DD HH:MM:SS] ERROR: ` の行で失敗を拾う。`WARN:` の行は失敗として拾わない。対象が0件のときを失敗にしないのは、フォルダを読めたうえで空であることは正常な状態でありうるためである。0件であることはレポートの警告で読み手に伝わる。

## 実行の流れ

1. `STATE_DIR/lock` を mkdir で作り、作れなければ二重起動として終了コード1で終わる。終了時に消す。
2. 通常実行では、以降の出力を `STATE_DIR/logs/<YYYY-MM-DD-HHMMSS>.log` へ書く。30件を超えた古いログは削除する。
3. 対象を巡回してレポートを書く。

### lock が残った場合

プロセスが強制終了されると `STATE_DIR/lock` が残り、以後の起動が拒否される。実行中のものが無いことを確かめてから `rmdir ~/.local/state/claude-reports/repo-patrol/lock` で消す。

## SessionStart の hook からの起動

launchd では起動しない。launchd から起動した `/bin/bash` は、macOS のプライバシー保護（TCC）により `~/Documents` などの一覧を拒否される。Claude Code の hook はターミナルの権限で動くため読める。

`run-if-due.sh` の流れは次のとおりである。標準出力と標準エラーには何も出さず、常に終了コード0で終わる（SessionStart の hook の出力は会話に入るため）。

1. 今日の結果（`CLAUDE_REPORTS_ROOT/repo-patrol/<YYYY-MM-DD>.md`）があれば何もしない。土日も動く。
2. `REPO_PATROL_ROOT` を `ls` で一覧できなければ何もしない。結果もログも書かず、次のセッションに持ち越す。`STATE_DIR/skipped.log` に日時と理由を1行だけ残す。launchd などから起動した `claude -p`（定期実行）でもこの hook が走り、TCC で読めずに失敗の知らせが出るのを避けるためである。
3. `STATE_DIR/trigger.lock` を mkdir で作り、作れなければ何もしない。同時に複数のセッションが始まっても1回だけ動かすためである。2時間より古い `trigger.lock` は、強制終了などで残ったものとみなして外す。
4. lock を取った後に、今日の結果が無いこと、`patrol.sh` の lock（`STATE_DIR/lock`）が無いことを改めて確かめる。
5. `patrol.sh` を `nohup` で切り離して動かし、すぐに戻る。`patrol.sh` が終わると `trigger.lock` を外す。

hook はリポジトリの `install.sh` が、使っている各 settings.json の `hooks.SessionStart` に登録する。手で登録するときは、次のコマンドを足す（timeout は 5 秒）。

```sh
"$HOME/.claude/skills/repo-patrol/scripts/run-if-due.sh"
```

手動で動かすときは `patrol.sh` を直接呼ぶ（同日の2回目は連番になる）。
