# skill-audit scripts

Skill `skill-audit` を週1回、非対話で起動するためのスクリプト群である。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `lib.sh` | 共通定義（`ROOT`、`STATE_DIR`、除外名の配列 `EXCLUDE_NAMES`、`list_targets`、jobs.conf の読み込み、設定ディレクトリの一覧）。各スクリプトが source する |
| `snapshot.sh <スキル名> <相対パス>` | 修正前のファイルを `STATE_DIR/history/<YYYY-MM-DD>/<スキル名>__<相対パス>.bak` へ退避する。同日の2回目以降は上書きしない |
| `trash-skill.sh <スキル名>` | スキルのディレクトリを `ROOT/.skill-audit-trash/<YYYY-MM-DD-HHMMSS>-<スキル名>/` へ移動する。削除はしない |
| `run-audit.sh [--force] [--dry-run]` | 変更を検出し、権限を絞った `claude` で精査を起動する。実行の前後を比べ、変更ごとに承認が要るかを判定し、要らないものは残して記録し、要るものは戻して承認待ちにする |
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
| `CLAUDE_REVIEW_PROPOSALS` | `${CLAUDE_REPORTS_ROOT:-$HOME/claude-reports}/proposals` | 承認待ちの置き場所。否認リスト `rejections.md` と訂正リスト `corrections.md` もここにある |
| `SKILL_AUDIT_PROTECTED` | `security-rules commit-guard` | 修正・削除を常に承認待ちに回すスキル（安全のための規則。空白区切り）。claude の書き換えも、リンクの表記と実体の両方で拒否する。jobs.conf にも書ける |
| `CLAUDE_REVIEW_GUARDED_PATHS` | 各スキルの `scripts/`（`security-rules`・`memory-audit`・`report-inbox`・`repo-patrol`・`secret-patrol`・`skill-audit`・`feedback-mining`・`change-review`） | claude の書き換えを拒否するフックと定期実行のスクリプト（コロン区切り。スキルの置き場所からの相対パスか絶対パス）。jobs.conf にも書ける |
| `CLAUDE_REVIEW_APPROVAL_MODE` | `screen` | 承認の進め方。`screen`（承認あり）では修正・削除をすべて承認待ちにし、`auto`（承認なし）では承認が要るものだけを承認待ちにする。jobs.conf にも書ける |
| `CLAUDE_CHANGE_LEDGER` | `$HOME/.local/state/claude-change-ledger` | 変更の台帳（Skill `change-review` の `ledger.sh`）。承認なしで反映した変更の直す前と直した後の版をコミットする。claude の書き込みを拒否する。jobs.conf にも書ける |
| `CLAUDE_REPORTS_ROOT` | `$HOME/claude-reports` | 結果の置き場所の親。結果は `<ここ>/skill-audit/<YYYY-MM-DD>.md` に書く |
| `CLAUDE_REVIEW_STATE` | `$HOME/.local/state/claude-review-inbox` | 判断の台帳の置き場所。claude の書き込みを拒否する |
| `CHANGE_REVIEW_SCRIPTS` | なし | Skill `change-review` の scripts の場所。無ければ `<このスクリプトの場所>/../../change-review/scripts`、`ROOT/change-review/scripts`、各設定ディレクトリの `skills/change-review/scripts` の順に探す |

利用者の環境だけの決まりは、上書きファイル `${XDG_CONFIG_HOME:-~/.config}/claude-skills/skill-audit.local.md` に書く。`run-audit.sh` は、このファイルの Read を許可し、依頼文で場所を伝える。

## 対象範囲

ROOT 直下のディレクトリのうち、次を除いたものを対象とする。

- 名前が `.` で始まるもの
- `SKILL_AUDIT_EXCLUDE` に挙げた名前（既定は無し）
- シンボリックリンクのうち、実体が `OWN_LINK_ROOTS`（環境変数 `SKILL_AUDIT_OWN_LINK_ROOTS`、コロン区切り。既定は本リポジトリの `core/skills`）の下に無いもの。実体がその下にあるリンクは自作のスキルとして対象にし、実体の中身を複製・比較する。`trash-skill.sh` はリンクのスキルを移動しない

`claude -p` の権限はリンクをたどった先の実体のパスで判定される。そのため、スキルの置き場所の直下にあるリンクの実体には `Read(/<実体>/**)` を、対象のリンクの実体には `Edit(/<実体>/**)` を許可し、対象外のリンクの実体の `Edit` と、`CLAUDE.md`・`settings.json` 等の実体の `Edit` を拒否する。実体の列挙は `core/skills/change-review/scripts/link-scopes.sh` で行う。

Bash の許可は文字列の前方一致で判定される。そのため `snapshot.sh` と `trash-skill.sh` は、実体のパス・`ROOT/skill-audit/scripts/` を経由したパス・各設定ディレクトリの `skills` を経由したパス（`~` を展開した形）・`ROOT` からの相対パス（`skill-audit/scripts/...` と `./skill-audit/scripts/...`）の各形を許可する。依頼文では `ROOT/skill-audit/scripts/` の下の絶対パスを渡し、そのとおりに呼ばせる。実体のパスだけを許可すると、リンクの側のパスで呼んだ `snapshot.sh` が許可待ちで止まる。

設定ディレクトリの `skills` が ROOT へのリンクなら、そちらの表記でも対象外のディレクトリの `Edit` を拒否する。読み取りは `~/Library/CloudStorage` と `CLAUDE_REVIEW_DENY_READ` の各場所を拒否する。

変更の記録（`STATE_DIR/history.md`）と直す前の複製（`STATE_DIR/history/`）は ROOT の外にあるため、変更検出と比較の対象に入らない。claude には `Read(/STATE_DIR/history/**)`、`Read(/STATE_DIR/history.md)`、`Edit(/STATE_DIR/history.md)` を許可する。

## run-audit.sh の動作

1. `STATE_DIR/lock` を mkdir で作り、作れなければ二重起動として終了コード1で終わる。終了時に消す。
2. 通常実行では、以降の出力を `STATE_DIR/logs/<YYYY-MM-DD-HHMMSS>.log` へ書く。30件を超えた古いログは削除する。
3. 対象配下の全ファイルから sha256 を計算し、`STATE_DIR/last-hash` と同じで `--force` が無ければ「変更なし」と書いて終了コード0で終わる。
4. 許可と拒否の規則を組み立てる。拒否には承認待ちの置き場所と判断の台帳への `Edit` を含める。南京錠として、`change-review/scripts/link-scopes.sh` の `guard_deny_rules` が出す規則（`SKILL_AUDIT_PROTECTED` のスキル全体・`CLAUDE_REVIEW_GUARDED_PATHS` のスクリプト・各設定ディレクトリの `CLAUDE.md`・`settings.json`・`settings.local.json`・変更の台帳を、リンクの表記と実体のパスの両方で）も拒否に入れる。拒否の規則は許可の規則より優先するため、自作のスキルの実体に `Edit` を許可していても、その中の `scripts/` は書き換えられない。`link-scopes.sh` を読み込めなければ、規則を作れないため起動せずに終了コード1で終わる。`--permission-mode default` を付け、settings.json の `defaultMode`（acceptEdits 等）で作業場所の中の編集が通らないようにする。行き先の表を書く `STATE_DIR/runs/<日時>/destinations/` への `Read` と `Edit`、承認が要る変更の一覧 `STATE_DIR/runs/<日時>/needs-approval.tsv` への `Edit` は許可する。依頼文に訂正リストの場所と `needs-approval.tsv` の書き方を足す。`change-review` が見つかれば、依頼文に行き先の表と移し先の書き方（`destinations.sh --print-rule` の出力）を足す。
5. 対象のスキル群を `STATE_DIR/runs/<日時>/before/` へ複製する（10回分を残す）。`.skill-audit-trash/` の中身の一覧も控える。
6. cwd を ROOT にして `CLAUDE_LAUNCHER`（既定 `claude`）を起動する。起動に使うコマンドをログに書く。依頼文で否認リストと上書きファイルのパスを渡す。
7. 終了コードによらず、実行の前後を比べ、変更ごとに承認が要るかを判定する（`approval_reason`）。承認が要るのは、`needs-approval.tsv` の1列目が対象そのもの（またはそれを含むスキルのディレクトリ）に一致するもの、`change-review/scripts/corrections.sh count skill-audit/<追加|修正|削除>/<スキル名>` が2以上のもの、`SKILL_AUDIT_PROTECTED` のスキルの修正・削除、差分の `-` 行が `permissions.deny`・`gitleaks`・`秘密の検査` を含むもの、行き先のフォルダに `moves.tsv` があるか `table.md` に「（候補なし）」があるもの、承認の進め方が `screen`（承認あり。既定）のときの修正・削除である。`change-review` が見つからなければ、修正と削除は承認が要るとみなす（追加は残す）。
   - 承認が要らない変更・新しいファイル・新しいスキルは残す。ID（`skill-audit-<実行の日時>-<連番>`）を振り、直す前の版を `STATE_DIR/history/<日付>/<スキル名>__<相対パスの / を _ にした名前>.bak`（スキルの削除は `<スキル名>__skill/`）へ複製する（既にあれば最初の版を残す）。あわせて `change-review/scripts/ledger.sh record` で、直す前と直した後の版を変更の台帳にコミットする（記録に失敗したら `history.md` の注意に書く）。
   - 承認が要る修正・ファイルの削除は、`change-review/scripts/diff-label.sh` で差分を作ってから実行前の版に戻し、`propose.sh` で承認待ちを1件ずつ作る。理由に判定の根拠を書く。
   - 承認が要るスキルの削除は、実行中に `.skill-audit-trash/` へ移されたものを元の場所へ戻し（無ければ複製から戻す）、全ファイルの削除の差分を1件の承認待ちにする。差分の `-` 行がそのスキルの名前を含む修正は、別の案にせず、このスキルの削除の案に入れる。承認が要らないスキルの削除は退避先に残し、参照の修正も残す。
   - 案には、claude が `runs/<日時>/destinations<対象の元の位置を写した場所>/` に書いた「消える記述の行き先」の表と、`moves.tsv` に挙げた移し先への追加の差分を入れる（Skill `change-review` の「2.2」）。表が無い・移し先の候補が無い・移し先の差分が作れない案は、見出しに「（移し先の確認が必要）」が付く。
   - `moves.tsv` に挙がった移し先のファイルを claude が直接書き換えていたら、追加だけの変更でも実行前の版に戻し、`history.md` の注意に書く。
   - `change-review` が見つからなければ、戻すだけで承認待ちは作らず、その旨を記録する。
8. 承認なしで反映した変更か承認待ちがあれば、`STATE_DIR/history.md` の冒頭の `---` の次へ記録を足す。ファイルが無ければ、冒頭の説明と `---` を作ってから足す。同じ内容を結果 `CLAUDE_REPORTS_ROOT/skill-audit/<YYYY-MM-DD>.md` の「承認なしで反映した変更と承認待ち」の節に書く。同じ実行で公開版の点検が結果を書いていれば、そのファイルへ足す。
9. 終了コード0のときだけ、再計算した hash で `last-hash` を更新する。

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
