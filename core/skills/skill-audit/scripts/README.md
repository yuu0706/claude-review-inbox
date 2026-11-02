# skill-audit scripts

Skill `skill-audit` を週1回、非対話で起動するためのスクリプト群である。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `lib.sh` | 共通定義（`ROOT`、`STATE_DIR`、除外名の配列 `EXCLUDE_NAMES`、`list_targets`、jobs.conf の読み込み、設定ディレクトリの一覧）。各スクリプトが source する |
| `snapshot.sh <スキル名> <相対パス>` | 修正前のファイルを `STATE_DIR/history/<YYYY-MM-DD>/<スキル名>__<相対パス>.bak` へ退避する。同日の2回目以降は上書きしない |
| `trash-skill.sh <スキル名>` | スキルのディレクトリを `ROOT/.skill-audit-trash/<YYYY-MM-DD-HHMMSS>-<スキル名>/` へ移動する。削除はしない |
| `run-audit.sh [--force] [--dry-run]` | 変更を検出し、権限を絞った `claude` で精査を起動する。作業用の複製で差分を作り、追加・修正・削除・統合を記録へ足す。元の対象は変更しない |
| `check-public.sh` | 公開版のディレクトリの一覧（`public-dirs.txt`）の各ディレクトリを共通の検査器の `check.sh` で調べ、当たり・失敗・検査器が無いことを `~/claude-reports/skill-audit/<YYYY-MM-DD>.md` に書く。`run-audit.sh` が `--dry-run` 以外で毎回呼ぶ。公開版は直さない |
| `test.sh` | 一時ディレクトリに偽の ROOT を作って上記を検査する。実際の claude は起動しない |

## 環境変数

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `SKILL_AUDIT_ROOT` | `$HOME/.claude/skills` | スキルのルート（ROOT） |
| `SKILL_AUDIT_EXCLUDE` | なし | ROOT 直下で精査の対象から外す名前（空白区切り）。同期やプラグインの置き場所、外部から導入したスキルを指定する |
| `SKILL_AUDIT_OWN_LINK_ROOTS` | 本リポジトリの `core/skills` | 実体がこの下にあるリンクを自作のスキルとして扱う（コロン区切り） |
| `SKILL_AUDIT_STATE` | `$HOME/.local/state/skill-audit` | lock・last-hash・ログ・変更の記録（`history.md`）・直す前の複製（`history/`）の置き場 |
| `CLAUDE_LAUNCHER` | `claude` | 起動するコマンド。空白で区切った語のうち `{job}` は `skill-audit` に置き換える。検査では `true` や偽のスクリプトを指定する |
| `CLAUDE_REVIEW_CONFIG_DIRS` | `$HOME/.claude` | Claude の設定ディレクトリの一覧（コロン区切り）。存在するものだけを使う |
| `CLAUDE_REVIEW_DENY_READ` | なし | 読み取りを拒否する追加の場所（コロン区切り） |
| `CLAUDE_REVIEW_JOBS_CONF` | `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/jobs.conf` | 共通の設定ファイル。`SKILL_AUDIT_ROOT`・`SKILL_AUDIT_EXCLUDE`・`SKILL_AUDIT_OWN_LINK_ROOTS`・`CLAUDE_LAUNCHER`・`CLAUDE_REVIEW_CONFIG_DIRS`・`CLAUDE_REVIEW_DENY_READ` を `名前=値` の形で書ける。環境変数が優先する |
| `CLAUDE_REVIEW_PROPOSALS` | `${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals` | 否認リスト`rejections.md`と訂正リスト`corrections.md`の置き場所 |
| `SKILL_AUDIT_PROTECTED` | `security-rules commit-guard` | 修正・削除を常に`要確認`にするスキル（安全のための規則。空白区切り）。claude の書き換えも、リンクの表記と実体の両方で拒否する。jobs.conf にも書ける |
| `CLAUDE_REVIEW_GUARDED_PATHS` | 各スキルの `scripts/`（`security-rules`・`memory-audit`・`report-inbox`・`repo-patrol`・`secret-patrol`・`skill-audit`・`feedback-mining`・`change-review`） | claude の書き換えを拒否するフックと定期実行のスクリプト（コロン区切り。スキルの置き場所からの相対パスか絶対パス）。jobs.conf にも書ける |
| `CLAUDE_CHANGE_LEDGER` | `$HOME/.local/state/claude-change-ledger` | 過去の変更の台帳。新しい記録には使わない。claude の書き込みを拒否する。jobs.conf にも書ける |
| `CLAUDE_REVIEW_CHANGES_LOG` | `$HOME/.local/state/claude-reports/changes/log.md` | 直したいことの記録。シェルが追記し、Claudeの直接編集は拒否する |
| `CLAUDE_REPORTS_ROOT` | `$HOME/claude-reports` | 結果の置き場所の親。結果は `<ここ>/skill-audit/<YYYY-MM-DD>.md` に書く |
| `CLAUDE_REVIEW_STATE` | `$HOME/.local/state/claude-review-inbox` | 旧版から残る状態の置き場所。claude の書き込みを拒否する |
| `CHANGE_REVIEW_SCRIPTS` | なし | Skill `change-review` の scripts の場所。無ければ `<このスクリプトの場所>/../../change-review/scripts`、`ROOT/change-review/scripts`、各設定ディレクトリの `skills/change-review/scripts` の順に探す |

利用者の環境だけの決まりは、上書きファイル `${XDG_CONFIG_HOME:-~/.config}/claude-skills/skill-audit.local.md` に書く。`run-audit.sh` は、このファイルの Read を許可し、依頼文で場所を伝える。

## 対象範囲

ROOT 直下のディレクトリのうち、次を除いたものを対象とする。

- 名前が `.` で始まるもの
- `SKILL_AUDIT_EXCLUDE` に挙げた名前（既定は無し）
- シンボリックリンクのうち、実体が `OWN_LINK_ROOTS`（環境変数 `SKILL_AUDIT_OWN_LINK_ROOTS`、コロン区切り。既定は本リポジトリの `core/skills`）の下に無いもの。実体がその下にあるリンクは自作のスキルとして対象にし、実体の中身を複製・比較する。`trash-skill.sh` はリンクのスキルを移動しない

`claude -p`は元のROOTとリンク先の実体を読み取り専用とする。
編集は作業用の複製と、行き先の表・`needs-approval.tsv`だけに許可する。
元のROOT、設定、否認リストと訂正リスト、旧版の状態、過去の台帳、変更の記録は書き換えを拒否する。
安全のための規則とフック・定期実行のスクリプトは、リンクの表記と実体の両方を守る。
`link-scopes.sh`が権限を組み立て、作れなければ起動しない。
`--permission-mode default`を使う。
読み取りは同期フォルダと`CLAUDE_REVIEW_DENY_READ`の各場所を拒否する。

`snapshot.sh`と`trash-skill.sh`は会話で実際に直すために残す。
定期実行は元のスキルをこれらのスクリプトで変更しない。
`history.md`と直す前の複製は過去の記録として残す。
定期実行は`history.md`へ反映の記録を足さない。

## run-audit.shの動作

1. `STATE_DIR/lock`をmkdirで取り、二重起動なら終了コード1で終わる。終了時に消す。
2. 通常実行の出力を`STATE_DIR/logs/<YYYY-MM-DD-HHMMSS>.log`へ書く。30件を超えた古いログは削除する。
3. 対象のsha256を`last-hash`と比べる。同じで`--force`が無ければ精査を省略する。
4. 元のスキルを`STATE_DIR/runs/<日時>/before/`と同じ階層の`staging/`へ複製する。作業用のフォルダと権限を用意する。
5. `CLAUDE_LAUNCHER`で精査を起動する。元のパスと作業用のパス、否認リストと訂正リスト、上書きファイルの場所を伝える。
6. 作業用の差分から追加・修正・削除・統合を取り出す。追加は`new-change.sh`、修正・削除は`propose.sh`で記録する。
7. 結果の「記録に足した直したいこと」にID・区分・対象・要約を書く。公開版の点検の結果があれば同じファイルへ足す。
8. 正常終了した場合だけ`last-hash`を更新する。

新規スキルは、元の置き場所に同名の項目が無く、作業用の非リンクディレクトリに`SKILL.md`がある場合だけ記録する。
対象外の既存項目と同名の候補や、単独のファイルを新規スキルとして扱わない。

削除の候補は`STATE_DIR/runs/<日時>/deletions.tsv`へ「元の絶対パス<TAB>理由」で書く。
区分は同じ階層の`needs-approval.tsv`の理由と、Skill `change-review`の「0.1」の判定に従う。
訂正リストで同じ種類が2回訂正された変更、安全のための規則の変更、行き先の表の欠けは`要確認`にする。
種類は`skill-audit/<追加|修正|削除>/<スキル名>`とする。

行き先の表は`STATE_DIR/runs/<日時>/destinations/<対象の元の位置を写した場所>/table.md`へ書く。
移し先への追加があれば、書き足した後の全文と`moves.tsv`も同じ場所に置く。
スキルの削除と、そのスキルを指す参照の修正は1件にまとめる。
移し先を含め、元の対象は変更しない。
`change-review`のスクリプトが無ければ、記録せず理由を結果に書く。
新しい変更を台帳へ記録しない。

公開版の点検は`--dry-run`以外で毎回行う。
スキルに変更が無く精査を省略する場合も点検する。
点検の条件と出力はSkill `skill-audit`の「2.8」に従う。

### --dry-run の扱い

- 変更検出は通常どおり行う。変更なしならスキップする。
- 起動せず、組み立てたコマンドを標準出力へ表示する。
- `last-hash` は更新しない。ログファイルも作らない。
- lock は通常どおり取る。

### lock が残った場合

プロセスが強制終了されると `STATE_DIR/lock` が残り、以後の起動が拒否される。実行中のものが無いことを確かめてから `rmdir ~/.local/state/skill-audit/lock` で消す。

## launchd への登録

ひな形は `../launchd/skill-audit.plist.template` にある。毎週月曜 10:00 に起動する。
リポジトリの `install.sh` が、登録してよいかを聞いたうえで、ラベルとパスを埋めた plist を `~/Library/LaunchAgents/` に置き、`launchctl bootstrap` で登録する。登録済みなら `launchctl bootout` してから登録し直す。

ラベルは次のとおりに決まる。

- 既定は `com.<ユーザー名>.skill-audit` である（ユーザー名のドットはハイフンに置き換える）。
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

ひな形を書き換えたときは、`install.sh --with-schedule` を実行し直す。
