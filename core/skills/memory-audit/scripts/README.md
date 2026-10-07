# memory-audit scripts

Skill `memory-audit` を週1回、非対話で起動するためのスクリプトである。起動の前に対象のメモリを複製する。claude には直した版を作業用のフォルダへ書かせ、正常終了した場合だけ、スクリプトが条件を満たすファイルのうち追加だけの変更を元のメモリへ書き戻し、既存の行を変える修正と削除の候補は Skill `change-review` の承認待ちにする。最後に複製との差分をレポートへ足す。

`claude -p` では `~/.claude` 配下（メモリの置き場所）が保護対象のファイルとして扱われ、`--allowedTools` で Edit を許可しても書き込めない（メッセージは "Claude requested permissions to edit ... which is a sensitive file."）。このため、メモリへの書き込みは claude ではなく `run.sh` が行う。

作業用のフォルダでも、パスに `.claude` という要素を含む場所への Write は拒否される。このため、作業用のフォルダの中では `.claude` で始まる要素の先頭のドットを外して写す。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `run.sh [--dry-run]` | 対象を複製し、権限を絞った `claude` で精査を起動し、直した版を書き戻し、差分をレポートへ足す |
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
| `CLAUDE_REVIEW_JOBS_CONF` | `${XDG_CONFIG_HOME:-~/.config}/claude-review-inbox/jobs.conf` | 上の3つを書く共通の設定ファイル |

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

あわせて、作業用のフォルダ `REPORTS_ROOT/memory-audit/.staging/<YYYY-MM-DD-HHMMSS>/` を作る。日時は複製と同じである。claude は直した版を、元の絶対パスの構造を保ってここへ書く。ただし、元の絶対パスの各要素のうち `.claude` で始まるもの（`.claude`・`.claude2` 等）は、先頭のドットを外した名前（`claude`・`claude2`）に置き換えて写す。

| 元の位置 | 作業用での位置 |
| --- | --- |
| `<HOME>/.claude/projects/<プロジェクト>/memory/foo.md` | `.staging/<日時><HOME>/claude/projects/<プロジェクト>/memory/foo.md` |
| `<HOME>/.claude-work/projects/<プロジェクト>/memory/foo.md`（2つ目の設定ディレクトリの例） | `.staging/<日時><HOME>/claude-work/projects/<プロジェクト>/memory/foo.md` |

複製（`.snapshots`）はシェルが書くため、元の絶対パスのまま保つ。

どちらもドット始まりのフォルダにしてある。Markdown の閲覧ツール等の一覧に複製が混ざらないようにするためである。Skill `report-inbox` もドット始まりのフォルダを数えない。

cwd をレポートの置き場所（`REPORTS_ROOT/memory-audit/`）にして、次を起動する。`<CLAUDE_LAUNCHER>` の既定は `claude` である。

```text
<CLAUDE_LAUNCHER> -p "<依頼文>" --model opus --effort low --allowedTools ... --disallowedTools ...
```

依頼文: 「Skill memory-audit を自動モードで実行する。対象のメモリは <対象ディレクトリを空白区切り>、直す前の複製は <.snapshots のパス>、直した版の書き込み先は <.staging のパス>（元の絶対パスの構造を保ち、.claude で始まる要素は先頭のドットを外して写す）、レポートの出力先は <レポートのパス>。対象ごとの元の位置と書き込み先での位置は次のとおり: <元の位置> → <作業用での位置>、…（対象ごとに読点で区切る）。メモリは直接直さず、書き込み先へ直した版を書く。否認リストは <承認待ちの置き場所>/rejections.md にある。始める前に読み、否認リストと同じ対象・同じ趣旨の修正・削除は作らない。利用者の環境だけの決まりは <上書きファイル> にある（無ければ飛ばす）。削除の候補は <.staging のパス>/deletions.tsv に「元の絶対パス<TAB>理由」の形で1行1件書く。削除の候補のメモリを指す索引（MEMORY.md）の行は消さない（シェルが削除の案に含める）。<行き先の表と移し先の書き方（change-review/scripts/destinations.sh --print-rule <.staging のパス>/destinations の出力）>」

| 区分 | 規則 |
| --- | --- |
| 許可 | `Skill` `Bash(which:*)`、`Read(/<範囲>/**)`（各設定ディレクトリ・`~/.agents`・`REPORTS_ROOT`・`STATE_BASE`・承認待ちの置き場所・スキルの置き場所の直下にあるリンクの実体）、`Read(/<上書きファイル>)`、`Edit(/<REPORTS_ROOT>/memory-audit/.staging/<日時>/**)`、`Edit(/<REPORTS_ROOT>/memory-audit/*.md)` |
| 拒否 | `Read(/<HOME>/Library/CloudStorage/**)`、`CLAUDE_REVIEW_DENY_READ` の各場所の `Read(/<場所>/**)`、`Edit(/<REPORTS_ROOT>/memory-audit/.snapshots/**)`、設定ディレクトリごとの `Edit(/<設定ディレクトリ>/CLAUDE.md)` `Edit(/<設定ディレクトリ>/settings.json)` `Edit(/<設定ディレクトリ>/skills/**)`、`Edit(/<HOME>/Documents/**)`、`Edit(/<承認待ちの置き場所>/**)`、`Edit(/<台帳の置き場所>/**)`、対象ごとの `Edit(/<対象>/**)`。CLAUDE.md・settings.json がリンクなら実体のパスでも拒否する |

rm・mv・aws・curl は許可しない。メモリの削除は自動では行わず、削除の候補を `deletions.tsv` に書かせる。
承認待ちの置き場所は `CLAUDE_REVIEW_PROPOSALS`（既定 `REPORTS_ROOT/proposals`）、判断の台帳の置き場所は `CLAUDE_REVIEW_STATE`（既定 `~/.local/state/claude-review-inbox`）である。台帳への書き込みを claude に許すと、画面のボタンを経ない承認を作れてしまうため拒否する。

## 書き戻し

claude が終了コード0で終わった場合だけ、`.staging/<日時>/` 配下の各ファイルのうち、次をすべて満たすものを元の場所へ `cp -p` で書き戻す。

元の場所は、targets.conf から求めた対象ごとの「作業用での位置 → 元の位置」の対で照合して求める。ファイルの親のディレクトリが、ある対象の作業用での位置と一致すれば、その対象の直下の同名のファイルを元の場所とする。文字列の置換で推測しないため、どの対象にも当たらないファイル（元の絶対パスのまま `.claude` を含めて書いたものを含む）は書き戻さない。

- パスに `..` を含まない（ファイル名の一部に含む場合も書き戻さない）。
- シンボリックリンクではない。
- 拡張子が `.md` である。
- 上の照合で、対象のメモリのディレクトリの直下に当たる（下位のディレクトリは書き戻さない）。
- 元の場所に同名のファイルが既にあり、それがシンボリックリンクではない（新しいファイルは作らない）。

満たさないファイルは書き戻さず、レポートの末尾に「書き戻さなかったファイル」の節としてパスと理由を足す。パスは、対象に当たったファイルは元の場所、当たらなかったファイルは作業用のフォルダでのパスを書く。該当が無ければ「なし」と書く。claude が異常終了した場合は何も書き戻さず、その旨を同じ節に書く。

### 追加だけを書き戻し、それ以外は承認待ちにする

上の条件を満たしたファイルは、元の場所と比べて次のとおり扱う。

| 比べた結果 | 扱い |
| --- | --- |
| 同じ | 何もしない |
| `diff -u` に `-` の行が無い（既存の行を変えない・消さない） | 書き戻す。レポートの「自動で反映した追加」に載せる |
| `-` の行がある | 書き戻さない。`change-review/scripts/diff-label.sh` で見出しを元の絶対パスにした差分を作り、`propose.sh` で承認待ちを1件作る |

`deletions.tsv` の各行は、元の絶対パスが対象のメモリのディレクトリの直下にある `.md`（`..` を含まない、シンボリックリンクでない、実在する）なら削除の差分の承認待ちにする。それ以外は「書き戻さなかったファイル」に理由を書く。

### 消える記述の行き先と、索引の行

修正と削除の案は `change-review/scripts/propose.sh` で作り、次を同じ案に入れる（Skill `change-review` の「2.2」）。

| 入れるもの | 作り方 |
| --- | --- |
| 「消える記述の行き先」の節 | claude が `<.staging のパス>/destinations<候補の元の位置を写した場所>/table.md` に書いた表。表が無ければ、その旨と見出しの「（移し先の確認が必要）」を付ける |
| 移し先への追加の差分 | 同じフォルダの `moves.tsv`（「移し先の絶対パス<TAB>書き足した後の版のファイル名」）。移し先は各設定ディレクトリの下の実在するファイルに限り、既存の行を変える版は認めない。移し先へは書き戻さない |
| 索引（`MEMORY.md`）の行の削除 | 削除の案だけ。同じディレクトリの `MEMORY.md` のうち `(<ファイル名>)` を含む行を消す差分 |

claude が `.staging` の `MEMORY.md` で削除の候補を指す行を消していた場合は、その行を戻した版で比べる（`change-review/scripts/memory-index.py keep`）。索引の行の削除だけの案は作らない。`destinations/` の下は書き戻しの対象にしない。

依頼文には、表と移し先の書き方（`destinations.sh --print-rule` の出力）を足す。

`change-review` の scripts は、`CHANGE_REVIEW_SCRIPTS`、`<このスクリプトの場所>/../../change-review/scripts`（スキル置き場の change-review）、各設定ディレクトリの `skills/change-review/scripts` の順に探す。見つからなければ、修正は書き戻さず承認待ちも作らず、「書き戻さなかったファイル」に理由を書く。

レポートには「自動で反映した追加と承認待ち」の節を足し、「自動で反映した追加 N件 / 承認待ちにした N件（番号）」と各ファイルを書く。

書き戻しで削除は一切しない。作業用のフォルダも自動では消さない。

## 変更の差分

書き戻しが終わったら、対象ごとに `diff -ru <複製> <現在>` を取り、レポートの末尾に「変更の差分」の節として足す。差分が無ければ「変更なし」と書く。

- 精査が異常終了しても差分は足す。終了コードは claude の終了コードを返す。
- レポートが作られていなければ、見出しと「レポートが作られませんでした」を書いてから差分を足す。

## 実行の流れ

1. `STATE_DIR/lock` を mkdir で作り、作れなければ二重起動として終了コード1で終わる。終了時に消す。
2. 通常実行では、以降の出力を `STATE_DIR/logs/<YYYY-MM-DD-HHMMSS>.log` へ書く。30件を超えた古いログは削除する。
3. targets.conf を展開し、対象を複製し、作業用のフォルダを作る。
4. `CLAUDE_LAUNCHER`（既定 `claude`）を起動する。起動に使うコマンドをログに書く。
5. 正常終了した場合だけ、作業用のフォルダから追加だけの変更を書き戻し、それ以外の修正と削除の候補を承認待ちにする。
6. 自動で反映した追加と承認待ち、書き戻さなかったファイル、差分をレポートへ足す。

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
