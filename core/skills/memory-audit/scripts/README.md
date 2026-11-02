# memory-audit scripts

Skill `memory-audit`を週1回、非対話で起動するためのスクリプトである。
対象のメモリを複製し、Claudeには直した版を作業用のフォルダへ書かせる。
シェルは追加・修正・削除・統合のすべてを「直したいこと」の記録へ足す。
元のメモリを書き戻したり削除したりしない。
会話のClaudeがSkill `change-review`の手順で入れる。

作業用のフォルダでも、パスに `.claude` という要素を含む場所への Write は拒否される。このため、作業用のフォルダの中では `.claude` で始まる要素の先頭のドットを外して写す。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `run.sh [--dry-run]` | 対象を複製し、権限を絞った `claude` で精査を起動し、直した版の差分を記録とレポートへ足す |
| `targets.conf` | 対象のメモリのディレクトリ。1行1パターン（glob 可） |
| `test.sh` | HOME を一時ディレクトリに差し替え、偽のメモリを作って `run.sh` を検査する。実際の claude は起動しない |

## 環境変数

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `CLAUDE_REPORTS_ROOT` | `$HOME/claude-reports` | レポート・複製・作業用のフォルダの置き場所。`memory-audit/` の下を使う |
| `CLAUDE_REPORTS_STATE` | `$HOME/.local/state/claude-reports` | lock とログの置き場所。`memory-audit/` の下を使う |
| `MEMORY_AUDIT_TARGETS` | `scripts/targets.conf` | 対象を書いた設定ファイル |
| `CLAUDE_LAUNCHER` | `claude` | 起動するコマンド。空白で区切った語のうち `{job}` はジョブ名（`memory-audit`）に置き換える。別のアカウントで起動するラッパーを使う場合に指定する。検査では偽のスクリプトを指定する |
| `CLAUDE_REVIEW_CONFIG_DIRS` | `$HOME/.claude` | Claude の設定ディレクトリの一覧（コロン区切り）。存在するものだけを使う。2つ目の設定ディレクトリを使う場合はここに足す |
| `CLAUDE_REVIEW_DENY_READ` | なし | 読み取りを拒否する追加の場所（コロン区切り）。クラウドストレージの同期フォルダ等を指定する |
| `CLAUDE_REVIEW_JOBS_CONF` | `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/jobs.conf` | 上の3つと下の4つを書く共通の設定ファイル |
| `CLAUDE_REVIEW_CHANGES_LOG` | `$HOME/.local/state/claude-reports/changes/log.md` | 直したいことの記録。シェルが追記し、Claudeの直接編集は拒否する |
| `CLAUDE_CHANGE_LEDGER` | `$HOME/.local/state/claude-change-ledger` | 過去の変更の台帳。新しい記録は作らず、Claudeの書き込みを拒否する |
| `SKILL_AUDIT_PROTECTED` | `security-rules commit-guard` | claude の書き換えを拒否する安全のための規則のスキル（空白区切り） |
| `CLAUDE_REVIEW_GUARDED_PATHS` | 各スキルの `scripts/`（フックと定期実行のスクリプト） | claude の書き換えを拒否するスクリプト（コロン区切り。スキルの置き場所からの相対パスか絶対パス） |

`CLAUDE_LAUNCHER`・`CLAUDE_REVIEW_CONFIG_DIRS`・`CLAUDE_REVIEW_DENY_READ` は、共通の設定ファイル（jobs.conf）に `名前=値` の形で書いてもよい。環境変数が設定ファイルより優先する。値の先頭の `~` は HOME に置き換える。jobs.conf は feedback-mining・skill-audit・secret-patrol も読む。

```text
CLAUDE_LAUNCHER=claude
CLAUDE_REVIEW_CONFIG_DIRS=~/.claude
CLAUDE_REVIEW_DENY_READ=
```

利用者の環境だけの決まりは、上書きファイル `${XDG_CONFIG_HOME:-~/.config}/claude-skills/memory-audit.local.md` に書く。`run.sh` は、このファイルの Read を許可し、依頼文で場所を伝える。

## targets.conf

既定の中身は次の1行である。

```text
$CONFIG_DIR/projects/*/memory
```

- 行頭の `$CONFIG_DIR` は、設定ディレクトリの一覧（`CLAUDE_REVIEW_CONFIG_DIRS`）の各要素に置き換える。
- 行頭の `$HOME`・`${HOME}`・`~` を展開する。それ以外の変数は展開しない（eval を使わないため）。
- glob を展開した結果のうち、存在するディレクトリだけを対象にする。シンボリックリンクは対象にしない。
- 空行と `#` で始まる行は飛ばす。
- 対象を1か所に絞るときは、このファイルの行を消すかコメントにする。スクリプトの変更は要らない。

対象が1件も無ければ、終了コード1で終わる（claude を起動せず、レポートも書かない）。

## 起動の内容

起動の前に、対象の全ディレクトリを `REPORTS_ROOT/memory-audit/.snapshots/<YYYY-MM-DD-HHMMSS>/` へ `cp -Rp` で複製する。元の絶対パスを複製先の下に保つ（例: `.snapshots/<日時><HOME>/.claude/projects/<プロジェクト>/memory`）。1件でも複製が失敗したら claude を起動せず、終了コード1で終わる。

あわせて、作業用のフォルダ `REPORTS_ROOT/memory-audit/.staging/<YYYY-MM-DD-HHMMSS>/` を作る。日時は複製と同じである。claude は直した版を、元の絶対パスの構造を保ってここへ書く。ただし、元の絶対パスの各要素のうち `.claude` で始まるもの（`.claude`・`.claude-work` 等）は、先頭のドットを外した名前（`claude`・`claude-work`）に置き換えて写す。

| 元の位置 | 作業用での位置 |
| --- | --- |
| `<HOME>/.claude/projects/<プロジェクト>/memory/foo.md` | `.staging/<日時><HOME>/claude/projects/<プロジェクト>/memory/foo.md` |
| `<HOME>/.claude-work/projects/<プロジェクト>/memory/foo.md`（2つ目の設定ディレクトリの例） | `.staging/<日時><HOME>/claude-work/projects/<プロジェクト>/memory/foo.md` |

複製（`.snapshots`）はシェルが書くため、元の絶対パスのまま保つ。

どちらもドット始まりのフォルダにしてある。Markdown の閲覧ツール等の一覧に複製が混ざらないようにするためである。Skill `report-inbox` もドット始まりのフォルダを数えない。

cwd をレポートの置き場所（`REPORTS_ROOT/memory-audit/`）にして、次を起動する。`<CLAUDE_LAUNCHER>` の既定は `claude` である。

```text
<CLAUDE_LAUNCHER> -p "<依頼文>" --model opus --effort low --permission-mode default --allowedTools ... --disallowedTools ...
```

依頼文には、対象・複製・作業用の場所・結果の出力先・元の場所と作業用の場所の対応を入れる。
否認リストと訂正リスト、上書きファイル、`deletions.tsv`、`needs-approval.tsv`の場所も伝える。
行き先の表の書き方は`destinations.sh --print-rule`の出力を足す。

| 区分 | 規則 |
| --- | --- |
| 許可 | 範囲を限った`Read`・`Skill`・`Bash(which:*)`と、作業用のフォルダ・結果への`Edit`を許可する |
| 拒否 | 同期フォルダと追加の読み取り拒否先への`Read`を拒否する。元のメモリ・複製・設定・スキル・否認リストと訂正リスト・旧版の状態・過去の台帳・変更の記録への`Edit`を拒否する |

南京錠は`change-review/scripts/link-scopes.sh`の`guard_deny_rules`を使う。
安全のための規則と定期実行のスクリプトは、リンクの表記と実体の両方で守る。
`--permission-mode default`を付け、規則を作れなければ起動しない。
Claudeにrm・mv・aws・curlは許可しない。

## 記録への追記

Claudeが正常終了した場合だけ、作業用の版と起動前の複製の差分を記録する。
実行中に別の会話が元のファイルを更新しても、その更新を消す差分を作らない。
対象のメモリの直下の`.md`だけを扱う。
パスに`..`を含むものとシンボリックリンクは扱わない。
対象との対応は、依頼文で使った元の場所と作業用の場所の対で確かめる。
文字列の置換で元の場所を推測しない。

- 追加は`change-review/scripts/new-change.sh`で記録する。
- 修正と削除は`propose.sh`で記録する。行き先の表と移し先への追加も同じ差分へ入れる。
- `deletions.tsv`の対象の削除と、そのメモリを指す`MEMORY.md`の行の削除は1件にする。
- 統合は、まとめ先への追加と、まとめられる側の削除・索引の変更を1件にする。
- 元のメモリと移し先は変更しない。台帳への記録や反映後の履歴も作らない。
- `change-review`のスクリプトが無ければ、記録せず理由を結果へ書く。

### 区分の判定

| 条件 | 扱い |
| --- | --- |
| `needs-approval.tsv`に対象がある | `要確認`にする |
| `corrections.sh count memory-audit/<追加\|修正\|削除>/<プロジェクト>/<ファイル名>`が2以上 | `要確認`にする |
| 差分の`-`行が安全のための規則を含む | `要確認`にする |
| 行き先の表が欠ける、候補が無い、移し先への差分が作れない | `要確認`にする |
| 上の条件に当たらず、Claudeも承認が要ると判断していない | `直してよい`にする |

詳しい条件はSkill `change-review`の「0.1」に従う。
`propose.sh`が区分を判定し、`new-change.sh`が排他をかけて追記する。

### 消える記述の行き先

作業用の`destinations/<候補の元の位置を写した場所>/`に`table.md`を置く。
移し先へ書き足す場合は、書き足した後の全文と`moves.tsv`も置く。
`moves.tsv`は「移し先の絶対パス<TAB>書き足した後の版のファイル名」とする。
移し先への差分は既存の行を変えない追加だけとし、実際のファイルへは書き込まない。

削除の候補の索引の行を作業用の`MEMORY.md`から消していた場合は、`memory-index.py keep`で戻して比較する。
索引の行の削除だけの記録を別に作らない。
`destinations/`・`deletions.tsv`・`needs-approval.tsv`をメモリとして記録しない。

`change-review`のスクリプトは`CHANGE_REVIEW_SCRIPTS`、隣の`change-review/scripts`、各設定ディレクトリの`skills/change-review/scripts`の順に探す。
結果へ「記録に足した直したいこと」の節を足し、ID・区分・対象・要約を書く。
記録できなかった候補は理由を書く。
元のメモリの差分は「変更なし」となる。

## 実行の流れ

1. `STATE_DIR/lock` を mkdir で作り、作れなければ二重起動として終了コード1で終わる。終了時に消す。
2. 通常実行では、以降の出力を `STATE_DIR/logs/<YYYY-MM-DD-HHMMSS>.log` へ書く。30件を超えた古いログは削除する。
3. targets.conf を展開し、対象を複製し、作業用のフォルダを作る。
4. `CLAUDE_LAUNCHER`（既定 `claude`）を起動する。起動に使うコマンドをログに書く。
5. 正常終了した場合だけ、作業用の版から追加・修正・削除・統合の差分を作り、記録へ足す。
6. 記録に足した直したいこと、記録しなかった候補、対象の変更の差分を結果へ足す。

### --dry-run の扱い

- 対象を `TARGET: <パス>` の形で表示し、組み立てたコマンドを表示する。
- 複製・作業用のフォルダ・起動・レポート・ログは作らない。

### 複製の扱い

複製（`.snapshots`）と作業用のフォルダ（`.staging`）は自動では削除しない。溜まったものは、中身を確かめてから手で消す。

### lock が残った場合

プロセスが強制終了されると `STATE_DIR/lock` が残り、以後の起動が拒否される。実行中のものが無いことを確かめてから `rmdir ~/.local/state/claude-reports/memory-audit/lock` で消す。

## launchd への登録

ひな形は `../launchd/memory-audit.plist.template` にある。毎週月曜 10:30 に起動する。
リポジトリの `install.sh` が、登録してよいかを聞いたうえで、ラベルとパスを埋めた plist を `~/Library/LaunchAgents/` に置き、`launchctl bootstrap` で登録する。登録済みなら `launchctl bootout` してから登録し直す。

ラベルは次のとおりに決まる。

- 既定は `com.<ユーザー名>.memory-audit` である（ユーザー名のドットはハイフンに置き換える）。
- `~/Library/LaunchAgents/` に、このジョブの起動スクリプトを指す plist が別のラベルで既にあれば、そのラベルを引き継ぐ。書き換える前の plist は `~/.local/state/claude-review-inbox/plist-backup/<日時>/` に複製する。

登録したラベルは、`~/.local/state/claude-review-inbox/scheduled-jobs.tsv` の2列目で確かめる。以下の `<ラベル>` はその値に置き換える。

登録の確認:

```sh
launchctl print gui/$(id -u)/<ラベル>
```

すぐに1回動かす:

```sh
launchctl kickstart gui/$(id -u)/<ラベル>
```

解除: リポジトリの `install.sh --uninstall` で、install.sh が登録した定期実行をすべて外す。このジョブだけを止める場合は、次を実行する。

```sh
launchctl bootout gui/$(id -u)/<ラベル>
```

ひな形を書き換えたときは、`install.sh --with-schedule` を実行し直す。plist の起動時刻に Mac がスリープしていた場合、launchd は復帰後に1回だけ起動する。
