# claude-review-inbox

| 項目 | 内容 |
| --- | --- |
| 対象 | Claude Code のスキル・メモリ・CLAUDE.md の直したいことの記録 |
| 動作環境 | 必須: macOS、Xcode のコマンドラインツール（`/usr/bin/python3` 3.9 以上の実体）。任意: `claude`（週1回の見直しに使う）。`install.sh` は `jq` を使わない（`memory-audit` のスクリプトは `/usr/bin/jq` を使う） |
| ライセンス | MIT（[LICENSE](LICENSE)） |

本書は、claude-review-inbox の入れ方・更新・外し方と、仕組みを説明する。

## 1. 概要

Claude Codeの決まり（スキル・メモリ・CLAUDE.md）の直したいことを、1本のMarkdownの記録に1件ずつ足す。定期実行は対象のファイルを直さない。会話のClaudeが記録を読み、区分に従って反映する。

- 記録は`~/.local/state/claude-reports/changes/log.md`に置く。環境変数`CLAUDE_REVIEW_CHANGES_LOG`で差し替えられる。書式は[core/skills/change-review/SKILL.md](core/skills/change-review/SKILL.md)が定める。
- 区分は`直してよい`と`要確認（理由）`とする。状態は`未対応`・`対応済み`・`見送り`とする。
- 出す前に否認リスト（`~/claude-reports/proposals/rejections.md`）と訂正リスト（同じ場所の`corrections.md`）を読む。同じ対象・同じ趣旨の却下済みの変更は出さない。
- 旧来の`~/claude-reports/proposals/*.md`の承認待ちの案は履歴として残し、新しくは作らない。

`install.sh` で入れると、次がそろう。

| 機能 | 内容 |
| --- | --- |
| 承認の決まり | Skill `change-review`。記録の書式・区分の判定・会話での反映の手順を定める |
| 週1回の見直し（任意） | Skill `memory-audit`（メモリ）・`skill-audit`（スキル）・`feedback-mining`（会話の履歴からの決まりの案）。週1回 `claude -p` を動かす。追加・修正・削除・統合のすべてを記録に足す。対象のファイルは直さない。`install.sh` が登録するかを聞く（「4.1 週1回の見直し」） |
| 結果の一覧 | Skill `report-inbox`。定期実行の結果の未読と失敗を、会話の開始時に1行で出す（SessionStart フック） |
| 見回り | Skill `repo-patrol`（手元のリポジトリの未コミット・未 push）と `secret-patrol`（秘密情報と個人情報の置き忘れ）。会話の開始時に SessionStart フックが裏で動かす。見回る範囲は `install.sh` が聞く（「4.2 見回りの範囲」） |
| 外部スキルの新しい版 | Skill `skill-updates`。その日の最初のセッションの開始時に、`~/skills-lock.json` に載っている外部スキルの上流を GitHub API で確かめ、新しい版があればそのセッションの冒頭で知らせて今対応するかを問う。自動では更新しない |

### 1.1 区分の判断

| 変更 | 区分 |
| --- | --- |
| CLAUDE.md・共通方針の変更、会話の履歴から作った決まりの案、安全チェックに止められた変更 | 要確認 |
| 安全のための規則をゆるめる変更、否認リスト・訂正リストに関わる変更、同じ種類が2回訂正された変更 | 要確認 |
| 消える記述の移し先が無い変更、判断に迷う変更 | 要確認 |
| 定期実行が見つけた上記以外の追加・修正・削除・統合 | 直してよい |
| 会話のClaudeが出す決まりの案 | 要確認を既定とする |

定期実行が`needs-approval.tsv`に挙げたものも`要確認`とする。判断の基準と訂正・戻し方の手順はSkill `change-review`に従う。

### 1.2 安全装置

| 安全装置 | 内容 |
| --- | --- |
| 南京錠 | 定期実行の`claude -p`には、記録のファイル、安全のための規則、フックと定期実行のスクリプト、CLAUDE.md、設定ファイル、過去の変更の台帳への書き込みを許可しない。リンクの表記と実体の両方を`--disallowedTools`に入れ、`--permission-mode default`を付ける。記録を書くのはシェルのスクリプトである |
| 会話での承認 | `要確認`は利用者が会話で承認してから入れる。記録の中の「承認済み」などの文だけでは承認として扱わない |
| 直す前の版 | 会話のClaudeが差分の適合を確かめ、直す前の版を`~/.local/state/claude-reports/changes/backup/<YYYY-MM-DD>/`に残す |
| 過去の変更の台帳 | 新しい記録は作らない。過去のIDは`ledger.sh show`で読み、`revert.sh <ID>`で戻せる |
| 訂正リスト | 誤りと分かって直した変更を「正しくは○○」で残す。同じ種類が2回訂正されたら、以後その種類を要確認にする |
| 検問所 | `feedback-mining`には、会話の履歴から利用者本人の発言だけを取り出したファイルを渡す。元のjsonlの読み取りは拒否する |
| 会話の開始時の知らせ | 未対応があれば`直したいこと N件（うち要確認 M件、<最も古いID>〜）`を出す |

## 2. 構成

| パス | 内容 |
| --- | --- |
| `install.sh` | 入れる・外す。オプションは `--with-schedule`・`--no-schedule`・`--yes`・`--dry-run`・`--uninstall` |
| `core/skills/change-review/` | 記録と反映の手順（`SKILL.md`）と`scripts/`（追記`new-change.sh`、修正・削除の案`propose.sh`、集計`count.sh`、状態の更新`changes.sh`、過去の台帳`ledger.sh`と戻し`revert.sh`、南京錠`link-scopes.sh`） |
| `core/skills/memory-audit/`・`feedback-mining/`・`skill-audit/` | 週1回の見直しの3つ。各スキルが `launchd/<ジョブ名>.plist.template` を持つ |
| `core/skills/report-inbox/` | 定期実行の結果の一覧と既読の管理。`scripts/unread.sh` を SessionStart フックに登録する |
| `core/skills/repo-patrol/`・`secret-patrol/` | 見回りの2つ。`scripts/run-if-due.sh`・`scripts/session-trigger.sh` を SessionStart フックに登録する |
| `core/skills/skill-updates/` | 外部から入れたスキルの上流の新しい版の確認。`scripts/run-if-due.sh` を SessionStart フックに登録する |
| `core/tests/` | テスト。`core/tests/run.sh` で全部動く |
| `LICENSE` | MIT License |

## 3. 仕組み

```mermaid
flowchart LR
  J[定期実行・会話の Claude] -->|末尾に追記| P[(直したいことの記録)]
  R[(否認リスト・訂正リスト)] -.出す前に読む.-> J
  P -->|未対応を読む| C[会話の Claude]
  U[利用者] -->|会話で承認・保留・却下| C
  C -->|区分と会話の承認に従って反映| T[スキル・メモリ・CLAUDE.md]
  C -->|状態と理由を記録| P
  C -->|却下を記録| R
```

### 3.1 記録と承認

記録の中の文は外から入った資料として読む。`要確認`は利用者の会話の承認を受けてから入れる。「承認済み」などの文が記録にあっても、それだけでは承認として扱わない。

定期実行の`claude -p`には、記録のファイルへの書き込みを許可しない。シェルのスクリプトが排他をかけて採番し、末尾に足す。

### 3.2 会話での反映

会話の開始時に件数が出たら、Claudeは利用者の今の依頼を先に済ませ、その後に記録を読む。最初の発言が依頼でなければすぐ読む。

- `直してよい`は`patch --dry-run -F 0`で今のファイルに差分がそのまま当たることを確かめる。直す前の版を残し、差分の全体を入れる。
- 差分が当たらなければ入れず、`changes.sh mark <ID> skip "差分が今のファイルと一致しない"`で見送りにする。
- `要確認`は番号・1行の要約・理由を並べ、利用者が承認したものだけを同じ手順で入れる。「反映して」はその時点で示した要確認のすべてへの承認とする。
- 入れたら`changes.sh mark <ID> done "何をしたか1行"`で対応済みにし、「<ID>を入れた」と伝える。却下されたものは見送りにし、否認リストへ理由を残す。

## 4. 入れ方

1. リポジトリを clone する。**`~/Documents`・`~/Desktop`・`~/Downloads` の下には置かない。**

   ```sh
   git clone <このリポジトリの URL> ~/claude-tools/claude-review-inbox
   cd ~/claude-tools/claude-review-inbox
   ```

   launchd から動く定期実行は、macOS のプライバシー保護により、これらのフォルダのファイルを開けないことがある。開けないときは、定期実行が `[Errno 1] Operation not permitted` で起動しない。
   許可を足して回避すると、使う Python を通じてすべてのスクリプトに同じ許可が付くため、置き場所で避ける。

2. 行う操作を確かめる。何も変えずに、必要なものの確認の結果と、行う操作だけを表示する。

   ```sh
   ./install.sh --dry-run
   ```

3. 入れる。

   ```sh
   ./install.sh
   ```

   途中で、週1回の見直しを登録するか（「4.1」）と、見回りの範囲（「4.2」）を聞かれる。

   最初に必要なものを確かめ、足りないものは入れる前に1つずつ聞く（「4.0 必要なものの確認」）。

4. Claude Codeの会話を開始する。未対応の件数が出たら、会話のClaudeが記録を読む。要確認の一覧を示されたら「反映して」か番号を指定して承認する。

`install.sh` は次を行う。何回実行しても結果は同じになる。

| No | 操作 | 備考 |
| --- | --- | --- |
| 1 | 必要なものを確かめ、足りないものは聞いてから入れる | 「4.0 必要なものの確認」を参照する |
| 2 | `core/skills/*`（全スキル）を、スキル置き場へシンボリックリンクで置く。旧版が置いた `review-loop` のリンク（このリポジトリを指すもの）は消す（`.trash` へは移さない） | スキル置き場は、各設定ディレクトリ（`~/.claude` と、共通の設定ファイルで指定した2つ目以降。「4.3 環境ごとの設定」）の `skills`。リンクなら実体を解決し、同じ実体へ二重に置かない。リンクに書かれたパスがリポジトリ内のパスと一致すれば何もしない。一致しないが実体をたどるとこのリポジトリを指すリンク（リポジトリを移す前の旧位置を経由するリンクなど）は、その場で張り直す。それ以外で同じ名前のものが既にあれば `<スキル置き場>/.trash/<YYYYMMDD-HHMMSS>-<名前>` へ移してから置く |
| 3 | 旧版の常駐サーバーを外す | `~/Library/LaunchAgents/com.*.claude-review-inbox.plist` のうち、このリポジトリの旧サーバーを指すものだけを `launchctl bootout` して plist を消す |
| 4 | 週1回の見直しを、聞いてから登録する | 「4.1 週1回の見直し」を参照する。旧版が登録した `review-loop` の定期実行は外す。登録した定期実行は `~/.local/state/claude-review-inbox/scheduled-jobs.tsv` に記録する |
| 5 | 見回りの範囲を聞き、設定ファイルに書く | 「4.2 見回りの範囲」を参照する |
| 6 | 各設定ディレクトリの `settings.json` の `hooks.SessionStart` に、`report-inbox` の `unread.sh`・`repo-patrol` の `run-if-due.sh`・`secret-patrol` の `session-trigger.sh`・`skill-updates` の `run-if-due.sh` を足す | Python（標準ライブラリの `json`）で行う。同じ文字列か、`~` と環境変数を展開してリンクを解決した先が同じファイルのコマンドが既にあれば足さない。書き換える前に `settings.json.bak-<YYYYMMDD-HHMMSS>` を残す。旧版が足した `core/hooks/session-start.sh` は外す |
| 7 | 記録の親ディレクトリと`~/claude-reports/proposals/`と`~/.local/state/claude-review-inbox/`を作る | 否認リストと訂正リストの置き場所は変えない |

設定は環境変数で変えられる。

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `CLAUDE_REVIEW_PYTHON` | `/usr/bin/python3` | `settings.json` を書き換える Python（3.9 以上）。指定したときは Xcode のコマンドラインツールを確かめない |
| `XDG_CONFIG_HOME` | `~/.config` | 見回りの範囲の設定ファイル `<XDG_CONFIG_HOME>/claude-review-inbox/patrol.conf` と、共通の設定ファイル `jobs.conf` の置き場所 |
| `CLAUDE_REVIEW_CONFIG_DIRS` | jobs.conf の値、無ければ `~/.claude` | スキルのリンクとフックを置く設定ディレクトリの一覧（コロン区切り）。`~/.claude` は常に含める |


### 4.0 必要なものの確認

`install.sh` は最初に次を確かめ、結果を表で表示してから進む。足りないものは、入れる前に1つずつ `[y/N]` で確かめる。`--yes` を付けると、すべて `y` と答えたものとして進む。

| No | 必要なもの | 確かめ方 | 無いときの扱い |
| --- | --- | --- | --- |
| 1 | Xcode のコマンドラインツール（必須） | `xcode-select -p` が成功し、その下に `usr/bin/python3` がある。`/usr/bin/python3` そのものは実行しない（無い Mac では入れる画面が開くため） | 「Xcode のコマンドラインツールを入れますか」と聞く。`y` なら `xcode-select --install` を実行し、終了コード 2 で終わる。画面の指示で入れ終えてから、もう一度 `./install.sh` を実行する。`N` なら、フックを設定できない旨を表示して終了コード 2 で終わる。`CLAUDE_REVIEW_PYTHON` を指定したときは確かめない |
| 2 | Python 3.9 以上（必須） | 1 の後に、使う Python で版を確かめる | 理由と、`CLAUDE_REVIEW_PYTHON` で別の Python を指定できる旨を表示して、終了コード 2 で終わる |
| 3 | `claude`（週1回の見直しに必要） | `command -v claude`、無ければ `~/.local/bin/claude`・`~/.claude/local/claude`・`/opt/homebrew/bin/claude`・`/usr/local/bin/claude` | フックの設定には不要。無ければ「claude が見つからないため、週1回の見直しは登録しません」と表示し、聞かずに登録しない（`--with-schedule` を付けても登録しない）。入れ方は利用者ごとに違うため、入れることはしない |

- 標準入力が端末でなく `--yes` も無いときは、何も入れない。必須のもの（1・2）が無ければ、足りないものと入れ方を表示して終了コード 2 で終わる。任意のものが無ければ、入れずに続ける。
- `--dry-run` では、確かめた結果と、入れるものの一覧を表示するだけで、何も入れない。必須のものが足りなければ終了コード 2 で終わる。

入れる途中で出る問いと許可は次のとおりである。これ以外の許可は求めない。

| 出るもの | いつ | なぜ |
| --- | --- | --- |
| Xcode のコマンドラインツールを入れる画面 | 1 で `y` と答えた直後 | macOS の `xcode-select --install` が開く。フックの設定に使う `/usr/bin/python3` の実体を入れるため |
| フォルダへのアクセスの許可 | 「4.2 見回りの範囲」で書類・デスクトップ・ダウンロードを入れた（またはその下のフォルダをリポジトリの置き場所にした）とき、初めて見回る時点 | `secret-patrol`・`repo-patrol` がそのフォルダを読むため。入れなければ出ない |

### 4.1 週1回の見直し

`memory-audit`（毎週月曜 10:30）・`feedback-mining`（毎週月曜 11:00）・`skill-audit`（毎週月曜 10:00）は、週1回 `claude -p` を動かす。**利用者の Claude の利用枠を使う。** そのため、`install.sh` は登録する前に1回だけ聞く。

| 実行のしかた | 見直しの扱い |
| --- | --- |
| `./install.sh`（端末から実行） | 「週1回の見直し（memory-audit・feedback-mining・skill-audit）を登録しますか。claude の利用枠を使います [y/N]」と聞く。`y` なら3つを登録し、それ以外なら登録しない（登録済みなら外す） |
| `./install.sh --with-schedule` | 聞かずに登録する |
| `./install.sh --no-schedule` | 聞かずに登録しない（登録済みなら外す） |
| 標準入力が端末でなく、上の2つの指定も無い | 登録しない。既に登録していれば、そのまま残す |
| `claude` が見つからない | 聞かずに登録しない |

- plist は各スキルの `launchd/<ジョブ名>.plist.template` から作る。ラベルの既定は `com.<ユーザー名>.<ジョブ名>` である。
- `~/Library/LaunchAgents/` に、同じジョブの起動スクリプトを指す plist が別のラベルで既にあれば、そのラベルを引き継ぐ。書き換える前の plist は `~/.local/state/claude-review-inbox/plist-backup/<YYYYMMDD-HHMMSS>/` に複製する。
- `skill-audit`の過去の変更の記録（`history.md`）と複製（`history/`）は、`${SKILL_AUDIT_STATE:-~/.local/state/skill-audit}/`に残す。新しい変更は直したいことの記録に足す。

### 4.2 見回りの範囲

`repo-patrol` と `secret-patrol` が、書類・デスクトップ・ダウンロードのフォルダと手元のリポジトリを見回るかは、`install.sh` が聞いて設定ファイル `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/patrol.conf` に書く。見回らないフォルダを不意に読み、macOS の許可のダイアログを出さないためである。

| 問い | 設定ファイルの項目 |
| --- | --- |
| 「書類・デスクトップ・ダウンロードのフォルダを、個人情報の置き忘れの見回りに入れますか。初めて見回るときに、macOS がフォルダへのアクセスの許可を求めます [y/N]」 | `PERSONAL_FOLDERS=yes` か `no`。`no` なら `secret-patrol` は Claude の記録と手元のリポジトリだけを見回る |
| 「手元のリポジトリを置いているフォルダを入力してください（例: ~/Documents/git。空なら見回りません）」 | `REPO_ROOTS=<フォルダ>`。複数はコロンで区切る（`repo-patrol` は先頭だけを使う）。`~/Documents`・`~/Desktop`・`~/Downloads` の下を答えたときは、許可のダイアログが出ることを表示する |

- 設定ファイルが既にあれば聞かずにその値を使う。変えるときはファイルを直す。
- `--yes` のときは聞かずに `PERSONAL_FOLDERS=no`・`REPO_ROOTS=`（空）とする。標準入力が端末でなく `--yes` も無いときは、聞かず、設定ファイルも書かない。
- 設定ファイルが無いまま見回りが動いたときは、3つのフォルダとリポジトリを見回らない。
- `--uninstall` は設定ファイルを消さない。

### 4.3 環境ごとの設定

定期実行の6つのスキルは、環境ごとの値を次の2種類のファイルから読む。どちらも無ければ既定値で動く。`install.sh` はどちらも作らない。

| ファイル | 読むもの | 書くもの |
| --- | --- | --- |
| `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/jobs.conf` | `install.sh`、`memory-audit`・`feedback-mining`・`skill-audit` の起動スクリプト、`secret-patrol` の `patrol.sh` | `名前=値` の行。値の先頭の `~` は HOME に置き換える。同じ名前の環境変数があれば、そちらを使う |
| `${XDG_CONFIG_HOME:-~/.config}/claude-skills/<スキル名>.local.md` | 各スキルの `SKILL.md`（最初に読むよう本文に書いてある）。自動の3つのジョブは、起動スクリプトがこのファイルの読み取りを許可する | 呼び名・区分の具体名・利用者の CLAUDE.md の節名など、本文の既定と違う決まり。本文と食い違う箇所はこちらが優先する |

jobs.conf に書ける項目:

| 項目 | 既定値 | 用途 |
| --- | --- | --- |
| `CLAUDE_LAUNCHER` | `claude` | 定期実行が起動するコマンド。空白で区切った語のうち `{job}` はジョブ名に置き換える。別のアカウントで起動するラッパーを使う場合に指定する |
| `CLAUDE_REVIEW_CONFIG_DIRS` | `~/.claude` | Claude の設定ディレクトリの一覧（コロン区切り）。2つ目の設定ディレクトリを使う場合に足す。スキルのリンクとフックを置く場所、メモリ・会話の履歴・スキル・settings.json の対象、読み取りの許可と書き込みの拒否の範囲がここから決まる |
| `CLAUDE_REVIEW_DENY_READ` | なし | 定期実行の claude に読ませない場所（コロン区切り）。クラウドストレージの同期フォルダなどを指定する。`~/Library/CloudStorage` は常に拒否する |
| `SKILL_AUDIT_ROOT` | `~/.claude/skills` | `skill-audit` が精査するスキルの置き場所 |
| `SKILL_AUDIT_EXCLUDE` | なし | `skill-audit` が名前で精査から外すもの（空白区切り） |
| `SKILL_AUDIT_OWN_LINK_ROOTS` | 本リポジトリの `core/skills` | 実体がこの下にあるリンクを、`skill-audit` が自作のスキルとして扱う（コロン区切り） |
| `SECRET_PATROL_SKILL_EXCLUDES` | なし | `secret-patrol` がスキルの置き場所で見回らない名前（空白区切り） |
| `SECRET_PATROL_HOOK_PATTERN` | なし | `secret-patrol` が、秘密の検査の hook とみなすコマンドに含まれる文字列。無ければ確かめない |
| `CLAUDE_REVIEW_CHANGES_LOG` | `~/.local/state/claude-reports/changes/log.md` | 直したいことの記録。環境変数で指定する |
| `CLAUDE_CHANGE_LEDGER` | `~/.local/state/claude-change-ledger` | 過去の変更の台帳の置き場所 |
| `SKILL_AUDIT_PROTECTED` | `security-rules commit-guard` | 安全のための規則のスキル（空白区切り）。定期実行の書き換えを拒否し、修正・削除は要確認として記録する |
| `CLAUDE_REVIEW_GUARDED_PATHS` | 各スキルの `scripts/`（`security-rules`・`memory-audit`・`report-inbox`・`repo-patrol`・`secret-patrol`・`skill-audit`・`feedback-mining`・`change-review`・`skill-updates`） | 定期実行の書き換えを拒否するフックと定期実行のスクリプト（コロン区切り。スキルの置き場所からの相対パスか絶対パス）。指定すると既定を置き換える |

例（2つ目の設定ディレクトリを使い、別のアカウントで起動するラッパーを使う場合）:

```text
CLAUDE_LAUNCHER=~/bin/claude-other-account {job}
CLAUDE_REVIEW_CONFIG_DIRS=~/.claude:~/.claude-work
CLAUDE_REVIEW_DENY_READ=~/Dropbox
```

## 5. 困ったとき

| 症状 | 確かめる場所と表示 | 原因と対処 |
| --- | --- | --- |
| 定期実行が起動しない | 各定期実行のログに `Operation not permitted` | macOS のプライバシー保護で launchd から開けない場所に置いている。`~/claude-tools` などへ移し、`./install.sh` を実行し直す |

## 6. 更新

```sh
cd ~/claude-tools/claude-review-inbox
git pull
./install.sh
```

スキルはリポジトリの中のディレクトリへのシンボリックリンクのため、`git pull` だけで新しい版になる。旧版から更新するときは `./install.sh` を実行し、旧版の常駐サーバーを外す。

## 7. 外し方

```sh
./install.sh --uninstall --dry-run   # 行う操作を確かめる
./install.sh --uninstall
```

`--uninstall` は次を行う。

- このリポジトリの旧サーバーを指す登録が残っていれば、launchd から外して plist を消す。
- `install.sh` が登録した定期実行（週1回の見直しの3つと、旧版の `review-loop`。`scheduled-jobs.tsv` に記録したもの）を外し、plist を消す。手で登録した plist のうち、`install.sh` が登録していないものは外さない。
- スキル置き場のうち、このリポジトリを指すシンボリックリンクだけを消す。
- `settings.json` から、足したフックだけを消す（書き換える前に `settings.json.bak-<YYYYMMDD-HHMMSS>` を残す）。
- `.trash` へ退避したスキルは自動では戻さず、戻すコマンド（`mv '<退避先>' '<元の場所>'`）を表示する。
- 直したいことの記録と否認・訂正リストと状態の置き場所は消さない。

## 8. 使い方

| したいこと | 方法 |
| --- | --- |
| 直したいことを見る | 会話で「直したいことを見せて」と伝える |
| 要確認を承認する | 一覧を示された会話で「反映して」（その時点で示した全部）か番号を伝える |
| 却下する | 番号と理由を伝える。記録は見送りにし、否認リストに理由を残す |
| 却下を取り消す | IDと理由を会話で伝える。利用者の承認を確かめて否認リストの該当行を消す |
| 定期実行の結果を見る | 会話で「未読の結果を見せて」と伝える。Skill `report-inbox`の手順で読み、既読にする |
| 入れた変更を戻す | 会話で「<ID>を戻して」と伝える。直す前の複製で戻す。過去の台帳のIDは`revert.sh <ID>`で戻す。誤りは訂正リストに残す |

## 9. テスト

```sh
core/tests/run.sh
```

| テスト | 確かめる内容 |
| --- | --- |
| `core/tests/test_changes.py` | 記録の追記と同時採番、区分の判定、件数の集計、状態の更新、差分の見出しとコードの囲み |
| `core/tests/test_install.sh` | 一時の`HOME`と偽の`launchctl`で、全スキルのリンク・4つのフック・2回実行・`--dry-run`・`--uninstall`・旧版の後始末・記録の親ディレクトリ・導入後の案内を確かめる |
| `core/tests/test_install_schedule.sh` | 一時の `HOME` と偽の `launchctl` で、週1回の見直しの登録（非端末・聞かれて `n`／`y`・`--with-schedule`・`--no-schedule`・`claude` が無いとき・2回実行・既存のラベルの引き継ぎ）、旧版の後始末、`--uninstall`、見回りの範囲の問いと `patrol.conf`、`--dry-run` の表示。端末からの実行は疑似端末で模す |
| `core/tests/test_install_prereq.sh` | 一時の`HOME`と偽のコマンドで、Xcodeのコマンドラインツール・Python・claudeの確認、非端末・`--yes`・`--dry-run`、jqを使わないフックの追加と削除を確かめる |
| `core/tests/test_link_scopes.sh` | 一時の `HOME` に実体が別のフォルダにあるリンクのスキルを置き、3つの定期実行の `--dry-run` の出力に実体の `Read` が1回ずつ入ること、実体の無いリンクで落ちないこと、リンクの先の実体の `Edit` を拒否すること |
| `core/tests/test_guard_rules.sh` | 南京錠: 3つの定期実行の `--dry-run` の `--disallowedTools` に、安全のための規則のスキル全体・フックと定期実行のスクリプト・`CLAUDE.md`・`settings.json`・`settings.local.json`・変更の台帳が、リンクの表記と実体のパスの両方で入ること、許可の側に入らないこと、`--permission-mode default` が付くこと、jobs.conf で一覧を変えられること |
| `core/tests/test_ledger.sh` | 変更の台帳: 記録（修正・追加・スキルの削除）とコミットのメッセージ、正しくない ID と相対パスの拒否、`revert.sh` で戻すこと・戻す前の内容を残すこと・2回目は戻さないこと |
| `core/tests/test_destinations.sh` | 修正と削除の案に付ける、消える記述の行き先 |
| `core/skills/*/scripts/test.sh` | 各スキル。起動するコマンドは常に `CLAUDE_LAUNCHER` で偽物に差し替え、本物の `claude` を起動しない。jobs.conf と環境変数の優先順位、設定ディレクトリが2つある場合、見回りの範囲の設定ファイルが無い・ある場合を含む |

テストは本物の`HOME`・`launchctl`・`xcode-select`・`claude` に触れない。`install.sh` が探す場所は、検査用の環境変数（`CLAUDE_REVIEW_XCODE_SELECT`・`CLAUDE_REVIEW_SYSTEM_PYTHON`・`CLAUDE_REVIEW_CLAUDE_PATHS`）で偽のコマンドに差し替える。

## 10. 元になった考え方

Claude が自分の決まり（スキル・メモリ・CLAUDE.md）を育てる仕組みでは、誤った修正が気付かれずに残りやすい。とくに定期実行は利用者が見ていない場で動く。そこで、定期実行はすべての変更を1本の記録に足し、対象のファイルを直さない。会話のClaudeが差分を確かめ、直してよいものを入れる。要確認は利用者の会話の承認を受けてから入れる。直す前の版と訂正リストで誤りに対処する。

## 11. ライセンス

MIT License である。全文は [LICENSE](LICENSE) にある。

## 12. 未検証の事項

launchdからの起動、実物の`claude -p` による週1回の見直しは、テストの偽のコマンドでしか確かめていない。導入後に各定期実行のログで確かめる。
