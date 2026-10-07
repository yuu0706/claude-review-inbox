# secret-patrol scripts

秘密情報と個人情報の置き忘れを見回り、結果を Markdown のレポートへ書くスクリプトである。claude は使わない。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `patrol.sh [--stdout] [--reset-baseline]` | 見回ってレポートを書く。`--stdout` はファイルへ書かず標準出力へ出す（ログを作らず、baseline も更新しない）。`--reset-baseline` は既知の指摘を消してから見回る |
| `session-trigger.sh` | Claude Code の SessionStart フックから呼ばれる。前回の起動から一定の日数（既定 7 日）がたっていれば、`patrol.sh` を裏で1回起動する。標準出力に何も出さず、すぐに終了コード 0 で終わる |
| `test.sh` | 一時ディレクトリに偽の利用者の環境と偽の gitleaks を作って `patrol.sh` を検査する。実際の `~/Documents`・`~/Downloads`・`~/.claude` は読まない。ネットワークは使わない |

## 環境変数

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `SECRET_PATROL_HOME` | `$HOME` | 見回りの起点。対象のパスはすべてこの下として組み立てる |
| `SECRET_PATROL_GITLEAKS` | `gitleaks` | gitleaks のコマンド名またはパス |
| `CLAUDE_REPORTS_ROOT` | `$HOME/claude-reports` | レポートの置き場所。`secret-patrol/<YYYY-MM-DD>.md` に書く |
| `CLAUDE_REPORTS_STATE` | `$HOME/.local/state/claude-reports` | lock・ログ・baseline・`last-trigger` の置き場所。`secret-patrol/` の下を使う |
| `SECRET_PATROL_INTERVAL_DAYS` | `7` | `session-trigger.sh` が `patrol.sh` を起動する間隔（日）。数字でなければ既定値を使う |
| `SECRET_PATROL_SCRIPT` | `session-trigger.sh` と同じディレクトリの `patrol.sh` | `session-trigger.sh` が起動するスクリプト。検査で差し替えるために使う |
| `CLAUDE_REVIEW_PATROL_CONF` | `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/patrol.conf` | 見回りの範囲の設定ファイル（`install.sh` が書く）。`PERSONAL_FOLDERS=yes` で書類・デスクトップ・ダウンロードを見回り、`REPO_ROOTS`（コロン区切り）のリポジトリを見回る。無ければどちらも見回らない |
| `CLAUDE_REVIEW_CONFIG_DIRS` | `$SECRET_PATROL_HOME/.claude` | Claude の設定ディレクトリの一覧（コロン区切り）。a と d の対象を作る |
| `SECRET_PATROL_SKILL_EXCLUDES` | なし | 各設定ディレクトリの `skills` の直下で見回らない名前（空白区切り）。同期やプラグインの置き場所を指定する |
| `SECRET_PATROL_HOOK_PATTERN` | なし | d で、秘密の検査の hook とみなすコマンドに含まれる文字列。無ければ hook は確かめない |
| `CLAUDE_REVIEW_JOBS_CONF` | `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/jobs.conf` | 上の3つを `名前=値` の形で書ける共通の設定ファイル。環境変数が優先する |

`PATH` は呼び出し元のものを先に置き、その後ろに `~/.local/bin`・`/usr/local/bin`・`/opt/homebrew/bin` などを足す。

## 対象

| 区分 | 対象 | 調べ方 |
| --- | --- | --- |
| a. Claude 自身の記録 | 設定ディレクトリごとの `projects/*/memory`・`skills`・`CLAUDE.md`・`rules`・`settings.json` | `gitleaks dir --redact`。スキルは `.` で始まるディレクトリ・`SECRET_PATROL_SKILL_EXCLUDES` の名前・`*/history/` を除く。リンクは実体のパスを渡す。リンクで同じ実体を指すものは、最初に現れた1つだけを見る |
| b. 手元のリポジトリ（作業ツリー） | `REPO_ROOTS` の各フォルダの直下、およびその1段下で `.git` を持つディレクトリ | コミットされうるファイル（`git ls-files -co --exclude-standard` が返す、追跡中のものと、追跡していないが無視もされていないもの）だけを `gitleaks dir --follow-symlinks --redact` で調べる。各ファイルへのリンクを同じ相対パスで `CLAUDE_REPORTS_STATE/secret-patrol/tree` に並べて渡し、結果のパスは元のリポジトリのパスに戻す。`.gitignore` 済みのファイル、入れ子のリポジトリ、作業ツリーに無いファイル、シンボリックリンクは調べない。追跡されている `node_modules`・`cdk.out`・`dist`・`build`・`.git`・`vendor`・`.next` も除く |
| b. 手元のリポジトリ（未push） | 同上 | `gitleaks git --redact --log-opts="@{u}..HEAD"`。上流が無ければ `--branches --not --remotes`。対象のコミットが無ければ gitleaks を呼ばない |
| c. 個人情報の置き忘れ | `PERSONAL_FOLDERS=yes` のときの `~/Downloads`・`~/Desktop`・`~/Documents`（`~/Documents/git` の中の `.git`・`node_modules` を除く）と、`REPO_ROOTS` のリポジトリの作業ツリー（b と同じディレクトリを除く。書類を見回ったときは、その下のリポジトリは書類の側で数える） | 拡張子 `.tsv`・`.csv`・`.txt`・`.json` のうち、メールアドレスらしき文字列を含む行が20行以上あるもの。`example.com`・`example.org`・`example.net` とそのサブドメインは数えない |
| d. 守りの設定 | 設定ディレクトリごとの `settings.json` | `permissions.deny` に6つの規則（`Read(//**/.env)`・`Read(//**/.env.*)`・`Read(~/.aws/credentials)`・`Read(~/.ssh/**)`・`Read(//**/*.pem)`・`Read(//**/*.key)`）があるか、`hooks.PreToolUse` に `SECRET_PATROL_HOOK_PATTERN` を含むコマンドの hook があるか（未設定なら「確かめていない」と書く） |

gitleaks の除外は、一時ファイルに作った設定ファイル（`[extend] useDefault = true` と `[allowlist] paths`）を `--config` で渡して行う。

JSON の解析は `osascript -l JavaScript` で行う。jq は使わない。launchd の下の python3 は `~/Documents` を開けない事例があるため使わない。

ネットワークは使わない。対象のファイルは読むだけで、書き換えない。

## 既知の指摘（baseline）

a と b は、対象ごとに `CLAUDE_REPORTS_STATE/secret-patrol/baseline/<区分>-<対象>.json` を置き、`--baseline-path` で渡して新しい指摘だけを出す。区分は `a`・`bt-tree`（作業ツリー）・`bg-git`（未push）である。

- 初回（baseline が無い）は全件を新規として出し、その結果を baseline として保存する。
- 新規が出たら、baseline なしでもう一度走らせ、今回の全件で置き換える。
- baseline は `--redact` 済みの結果なので、値は `REDACTED` に置き換わっている。
- `--reset-baseline` で消してから走る。

## レポートの構成

1. 作成日時・区分ごとの件数（新規・既知）
2. 新規の秘密: 区分 / ファイル:行 / ルール名 / コミット（未push のみ）の表。値と `Match` は書かない
3. 個人情報の置き忘れの候補: パス・行数・該当行の件数・最終更新日の表。中身は書かない
4. 守りの設定: 設定ディレクトリの settings.json ごとに deny（6つ中いくつ）と hook（あり/なし/確かめていない）
5. 読めなかった対象: パスと理由
6. 既知: 区分ごとの件数

何も無い区分は「該当なし」と書く。同日に2回目が走った場合は `<YYYY-MM-DD>-2.md` のように連番にする。

settings.json に規則が無いことは「未設定」と書くだけで、失敗にはしない。ファイルが無い場合も失敗にしない。

古い書き方（`Read(**/.env)`・`Read(**/.env.*)`・`Read(**/*.pem)`・`Read(**/*.key)`）だけがある項目は設定済みに数えず、「書き方が古い（作業場所の外を止めない）: <項目>」と書く。`**/` で始まる規則は作業場所からの相対で、作業場所の外のファイルを止めないためである。これも失敗にはしない。

## 失敗の扱い

gitleaks が見つからない場合、または対象のどれかが読めなかった場合（`Operation not permitted`・`Permission denied`・JSON の解析の失敗など）は、レポートを書いたうえで `ERROR:` の行を標準エラーに出し、終了コード1で終わる。1つの対象で失敗しても全体は止めない。report-inbox は最新のログの `[YYYY-MM-DD HH:MM:SS] ERROR: ` の行で失敗を拾う。

## 実行の流れ

1. `STATE_DIR/lock` を mkdir で作り、作れなければ二重起動として終了コード1で終わる。終了時に消す。
2. 通常実行では、以降の出力を `STATE_DIR/logs/<YYYY-MM-DD-HHMMSS>.log` へ書く。30件を超えた古いログは削除する。
3. gitleaks の結果は一時ディレクトリに置き、終了時に `trap` で消す。
4. 対象を見回ってレポートを書く。

### lock が残った場合

プロセスが強制終了されると `STATE_DIR/lock` が残り、以後の起動が拒否される。実行中のものが無いことを確かめてから `rmdir ~/.local/state/claude-reports/secret-patrol/lock` で消す。

## SessionStart フックへの登録

Claude Code の会話を始めたときに `session-trigger.sh` が呼ばれ、前回の起動から7日以上たっていれば `patrol.sh` を裏で1回起動する。gitleaks は事前に入れておく。

launchd から起動すると、macOS のプライバシー保護（TCC）により `~/Documents`・`~/Downloads`・`~/Desktop` が `Operation not permitted` で読めない。フックはターミナルの権限で動くため、これらを読める。

`session-trigger.sh` の動き:

1. 標準入力のフックの JSON は読み捨てる。
2. `CLAUDE_REPORTS_STATE/secret-patrol/lock` があれば起動しない。
3. `CLAUDE_REPORTS_STATE/secret-patrol/last-trigger`（起動した時刻の epoch 秒）から間隔以上たっていれば、`last-trigger` を今の時刻で書き換えてから `patrol.sh` を切り離して起動する。ファイルが無い、または中身が数字でなければ、間隔がたっているとみなす。
4. `last-trigger` を書く前に、見回る場所（`PERSONAL_FOLDERS=yes` のときの `SECRET_PATROL_HOME`（既定 `$HOME`）の `Documents`・`Downloads`・`Desktop`、`REPO_ROOTS` の各フォルダ）のうち存在するものを一覧できるかを確かめる。見回らない場所は一覧しない（macOS の許可のダイアログを出さないため）。1つでも一覧できなければ、何もせずに終了コード 0 で終わり、次の会話に持ち越す。launchd から起動された定期実行の `claude -p` でもフックが走り、そこでは TCC により読めないため、失敗する見回りで7日分の起動の権利を使わないようにしている。
5. 状態ディレクトリが作れない、`last-trigger` が書けないなどの失敗では起動せず、標準出力に何も出さずに終了コード 0 で終わる。

登録: リポジトリの `install.sh` が、使っている各 settings.json の `hooks.SessionStart` に登録する。手で登録するときは、配列に次の1要素を足す。`session-trigger.sh` には実行権限が要る（`chmod +x`）。

```json
{
  "hooks": [
    { "type": "command", "command": "$HOME/.claude/skills/secret-patrol/scripts/session-trigger.sh" }
  ]
}
```

すぐに1回動かす（間隔に関係なく見回る。`last-trigger` は変わらない）:

```sh
~/.claude/skills/secret-patrol/scripts/patrol.sh
```

間隔を変える: フックを呼ぶ環境で `SECRET_PATROL_INTERVAL_DAYS` を設定する。例えば上の `command` を `SECRET_PATROL_INTERVAL_DAYS=3 $HOME/.claude/skills/secret-patrol/scripts/session-trigger.sh` にする。次の会話の開始から効く。

以前に launchd へ登録していた場合は、`launchctl bootout gui/$(id -u)/<ラベル>` で外し、`~/Library/LaunchAgents/<ラベル>.plist` を消す。
