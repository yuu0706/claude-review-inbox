# feedback-mining scripts

Skill `feedback-mining` を週1回、非対話で起動するためのスクリプトである。前回の実行より後に更新された会話の履歴を選び、利用者本人の発言だけを取り出したファイル（検問所）の一覧を claude へ渡す。claude には元の会話の履歴（jsonl）を読ませない。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `run.sh [--dry-run]` | 対象の会話を選び、利用者の発言を取り出し、権限を絞った `claude` で収集を起動する |
| `extract-user.py <一覧> <出力先>` | 検問所。jsonl から利用者本人の発言だけを取り出し、会話ごとに Markdown のファイルを書く（次節） |
| `test.sh` | 一時ディレクトリに偽の会話の履歴を作って `run.sh` を検査する。実際の claude は起動しない |

## 環境変数

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `CLAUDE_REPORTS_ROOT` | `$HOME/claude-reports` | レポートの置き場所。`feedback-mining/<YYYY-MM-DD>.md` に書かせる |
| `CLAUDE_REPORTS_STATE` | `$HOME/.local/state/claude-reports` | lock・last-run・inputs・ログの置き場所。`feedback-mining/` の下を使う |
| `FEEDBACK_MINING_SOURCES` | 各設定ディレクトリの `projects`（コロン区切り） | 会話の履歴を探すディレクトリ（コロン区切り）。存在しないものは飛ばす |
| `CLAUDE_LAUNCHER` | `claude` | 起動するコマンド。空白で区切った語のうち `{job}` はジョブ名（`feedback-mining`）に置き換える。検査では偽のスクリプトを指定する |
| `CLAUDE_REVIEW_CONFIG_DIRS` | `$HOME/.claude` | Claude の設定ディレクトリの一覧（コロン区切り）。存在するものだけを使う |
| `CLAUDE_REVIEW_DENY_READ` | なし | 読み取りを拒否する追加の場所（コロン区切り） |
| `CLAUDE_REVIEW_JOBS_CONF` | `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/jobs.conf` | 上の3つを書く共通の設定ファイル。書き方は memory-audit の scripts/README.md を参照する |

利用者の環境だけの決まりは、上書きファイル `${XDG_CONFIG_HOME:-~/.config}/claude-skills/feedback-mining.local.md` に書く。`run.sh` は、このファイルの Read を許可し、依頼文で場所を伝える。

## 対象の会話の選び方

1. `FEEDBACK_MINING_SOURCES` の各ディレクトリの下にある `*.jsonl` をすべて探す。`<セッション>/subagents/` の下も含む。
2. `STATE_DIR/last-run` があれば、その更新日時より後に更新されたものを選ぶ。無ければ（初回）過去7日に更新されたものを選ぶ。
3. `claude -p` で起動したセッションを除く（次節）。
4. 選んだファイルの一覧を `STATE_DIR/inputs-<YYYY-MM-DD-HHMMSS>.txt` に書く。
5. 検問所（`extract-user.py`）で、各ファイルから利用者本人の発言だけを `STATE_DIR/extracted-<日時>/<連番4桁>.md` に取り出し、その一覧を `STATE_DIR/extracted-<日時>.txt` に書く。依頼文にはこの一覧のパスを含める。取り出し結果は10回分を残す。

件数が0なら claude を起動せず、「対象の会話なし」とだけ書いたレポートを出して終わる。取り出した発言が0件のときも claude を起動せず、その旨のレポートを出して `last-run` を更新する。

### 検問所（extract-user.py）

会話の履歴には、ツールの結果・フックの出力・貼り付けた文章など、利用者以外が書いた文章が混ざる。そのまま claude に読ませると、外から入った文が「利用者の指摘」として決まりの案に化けるおそれがある。以前は SKILL.md の指示（利用者の発言だけを拾う）だけで守っていたが、機械的に絞るためにこの前処理を通す。

| 除くもの | 判定 |
| --- | --- |
| 利用者の発言でない行 | `type` が `user` でない（assistant・system・summary 等）、`message.role` が `user` でない |
| Claude Code が差し込んだ行 | `isMeta`・`isCompactSummary`・`isVisibleInTranscriptOnly` が真、`toolUseResult` を持つ |
| ツールの結果 | `content` に `tool_result` を含む行は行ごと除く |
| スラッシュコマンドの展開とローカルのコマンドの出力 | `<command-name>`・`<command-message>`・`<command-args>`・`<local-command-stdout>` 等を含む行 |
| フックの出力 | `<system-reminder>…</system-reminder>` などの区画を中身ごと除く（残りの本文は残す） |
| 貼り付けた文章の中身 | `<pasted_content …>…</pasted_content>` を「（貼り付けあり）」に置き換える。閉じていなければ末尾まで |

取り出したファイルの見出しには、元の会話のパスを書く。claude は根拠としてそのパスを書くが、元のファイルは読めない（下の拒否の規則）。読めない行（JSON でない行）は飛ばす。

### claude -p で起動したセッションの見分け方

jsonl の各行には、起動の経路を表す `entrypoint` が入っている。観測した値は次のとおりである。

| entrypoint | 起動の経路 |
| --- | --- |
| `cli` | ターミナルの対話セッション |
| `sdk-cli` | `claude -p`（非対話） |
| `claude-vscode` | VS Code の拡張機能 |
| `claude-desktop` | デスクトップアプリ |

`run.sh` は、ファイルの中で最初に現れる `"entrypoint":"..."` の値が `sdk-cli` のファイルを除外する。`entrypoint` を持たないファイルは除外しない。

注意点:

- `sdk-cli` は Agent SDK から起動したセッションにも付く（観測では、SDK から起動したセッションは確認していない）。SDK 製のツールを対話の用途で使い始めた場合は、そのセッションも除外される。
- 親のセッションの `subagents/` の下のファイルは、親と同じ `entrypoint` を持つ。`-p` のセッションのサブエージェントも除外される。
- `entrypoint` の値は Claude Code の版によって変わりうる。版を上げた後は、値を確かめ直す。

## 起動の内容

cwd をレポートの置き場所（`REPORTS_ROOT/feedback-mining/`）にして、次を起動する。`<CLAUDE_LAUNCHER>` の既定は `claude` である。

```text
<CLAUDE_LAUNCHER> -p "<依頼文>" --model opus --effort low --permission-mode default --allowedTools ... --disallowedTools ...
```

依頼文: 「Skill feedback-mining を自動モードで実行する。対象の会話から利用者本人の発言だけを取り出したファイルの一覧は <extracted の一覧のパス>、レポートの出力先は <レポートのパス>。元の会話（jsonl）は読まない（権限で拒否している）。取り出したファイルの見出しにある元の会話のパスを、根拠として書く。否認リストは <承認待ちの置き場所>/rejections.md にある。決まりの案を作る前に読み、否認リストと同じ対象・同じ趣旨の案は作らない。利用者の環境だけの決まりは <上書きファイル> にある（無ければ飛ばす）。」

| 区分 | 規則 |
| --- | --- |
| 許可 | `Skill`、`Read(/<範囲>/**)`（各設定ディレクトリ・`~/.agents`・`REPORTS_ROOT`・`STATE_BASE`・承認待ちの置き場所・スキルの置き場所の直下にあるリンクの実体）、`Read(/<上書きファイル>)`、`Read(/<SKILL_AUDIT_STATE>/history.md)`、`Edit(/<REPORTS_ROOT>/feedback-mining/**)` |
| 拒否 | `Read(/<HOME>/Library/CloudStorage/**)`、`CLAUDE_REVIEW_DENY_READ` の各場所の `Read(/<場所>/**)`、設定ディレクトリごとの `Edit(/<設定ディレクトリ>/**)`、`Edit(/<HOME>/Documents/**)` `Edit(/<HOME>/.agents/**)` `Edit(/<承認待ちの置き場所>/**)` `Edit(/<台帳の置き場所>/**)`、南京錠（`change-review/scripts/link-scopes.sh` の `guard_deny_rules`。安全のための規則のスキル・フックと定期実行のスクリプト・設定ファイル・変更の台帳を、リンクの表記と実体のパスの両方で）、検問所として各設定ディレクトリの `projects` と `FEEDBACK_MINING_SOURCES` の各場所（表記と実体）の `Read(/<場所>/**/*.jsonl)` |

`--permission-mode default` を付け、settings.json の `defaultMode`（acceptEdits 等）で作業場所の中の編集が通らないようにする。`link-scopes.sh` を読み込めなければ、拒否の規則を作れないため起動せずに終了コード1で終わる。

承認待ちの置き場所は `CLAUDE_REVIEW_PROPOSALS`（既定 `REPORTS_ROOT/proposals`）、判断の台帳の置き場所は `CLAUDE_REVIEW_STATE`（既定 `~/.local/state/claude-review-inbox`）である。台帳への書き込みを claude に許すと、画面のボタンを経ない承認を作れてしまうため拒否する。

`Edit(...)` の規則は Write ツールにも効く。規則の中のパスは `/` で始まる絶対パスの前にさらに `/` を付けた形（`//<HOME>/...`）になる。これは Claude Code の権限規則で絶対パスを表す書き方である。

## 実行の流れ

1. `STATE_DIR/lock` を mkdir で作り、作れなければ二重起動として終了コード1で終わる。終了時に消す。
2. 開始時刻を一時ファイル（`run-started.<PID>`）に記録する。
3. 通常実行では、以降の出力を `STATE_DIR/logs/<YYYY-MM-DD-HHMMSS>.log` へ書く。30件を超えた古いログは削除する。
4. 対象の会話を選び、inputs を書く。0件ならレポートを書いて終わる。続けて検問所で利用者の発言を取り出す。取り出しに失敗したら終了コード1で終わり、`last-run` は更新しない。
5. `CLAUDE_LAUNCHER`（既定 `claude`）を起動する。起動に使うコマンドをログに書く。
6. 終了コードが0で、レポートが空でないときだけ、手順2の一時ファイルを `last-run` にする。実行中に更新された会話は次回の対象に入る。

### --dry-run の扱い

- 対象の選定と inputs の作成は通常どおり行う。
- 起動せず、組み立てたコマンドを標準出力へ表示する。
- `last-run`・レポート・ログは作らない。

### lock が残った場合

プロセスが強制終了されると `STATE_DIR/lock` が残り、以後の起動が拒否される。実行中のものが無いことを確かめてから `rmdir ~/.local/state/claude-reports/feedback-mining/lock` で消す。

## launchd への登録

ひな形は `../launchd/feedback-mining.plist.template` にある。毎週月曜 11:00 に起動する。
リポジトリの `install.sh` が、登録してよいかを聞いたうえで、ラベルとパスを埋めた plist を `~/Library/LaunchAgents/` に置き、`launchctl bootstrap` で登録する。登録済みなら `launchctl bootout` してから登録し直す。

ラベルは次のとおりに決まる。

- 既定は `com.<ユーザー名>.feedback-mining` である（ユーザー名のドットはハイフンに置き換える）。
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
