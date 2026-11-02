# report-inbox scripts

定期実行のジョブが `~/claude-reports/` に書いたレポートを一覧にし、未読を数え、既読にするスクリプトである。あわせて、定期実行のジョブの失敗（ログの ERROR と launchd の標準エラー）と、Skill `change-review` の直したいことの未対応の件数を知らせる。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `lib.sh` | 共通定義（置き場所、レポートの列挙、既読の照合、失敗の判定、未対応の変更の列挙）。各スクリプトが source する |
| `unread.sh` | 直したいことの未対応の件数、未読のレポート、未読の失敗を1行だけ標準出力へ出す。どれも無ければ何も出さない |
| `mark-read.sh <レポートのパス...>` / `--all` / `--failures` / `--failure <ジョブ名>` | 既読にする。`--all` は現在あるレポートと全ジョブの失敗の知らせを既読にする |
| `list.sh [--unread]` / `list.sh --failures` / `list.sh --changes` | レポートを新しい順に一覧にする。`--failures` は未読の失敗を、`--changes`は未対応の変更を一覧にする |
| `test.sh` | 一時ディレクトリに偽のレポートを作って上記を検査する |

## 環境変数

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `CLAUDE_REPORTS_ROOT` | `$HOME/claude-reports` | レポートの置き場所 |
| `CLAUDE_REPORTS_STATE` | `$HOME/.local/state/claude-reports` | 既読の記録の置き場所（`report-inbox/read.txt`・`report-inbox/failure-read/`）。repo-patrol・memory-audit・feedback-mining の状態ディレクトリ（`<ジョブ名>/`）の親でもある |
| `CLAUDE_REVIEW_CHANGES_LOG` | `$HOME/.local/state/claude-reports/changes/log.md` | 直したいことの記録 |
| `SKILL_AUDIT_STATE` | `$HOME/.local/state/skill-audit` | skill-audit の状態ディレクトリ |

失敗の判定に使う環境変数は、各ジョブのスクリプトが状態ディレクトリを決める変数と同じものである。

## レポートとして扱うもの

`REPORTS_ROOT/<ジョブ名>/` の直下にあり、名前が `<YYYY-MM-DD>.md` または `<YYYY-MM-DD>-<連番>.md` のファイルである。下位のディレクトリ（`memory-audit/.snapshots/`・`memory-audit/.staging/` など）の中は数えない。ドット始まりのディレクトリはジョブとしても数えない。`REPORTS_ROOT` 直下のファイルも数えない。否認リスト・訂正リストと過去の案を置く`REPORTS_ROOT/proposals/`は、ジョブとして数えない。

既読の記録 `read.txt` には、既読にしたレポートの絶対パス（シンボリックリンクを解決したもの）を1行ずつ書く。

`unread.sh` と `list.sh` は、`read.txt` を awk で1回だけ読み込み、レポートの一覧と照合する（`lib.sh` の `list_reports_marked`）。既読の件数が増えても、1件あたりの照合の時間は増えない。`mark-read.sh` は従来どおり `read.txt` を1つの文字列として読み込んで照合するため、既読が多いと `--all` が遅くなる。

## unread.sh

出力の形:

```text
未読の結果: feedback-mining 1件（2026-10-05）、repo-patrol 3件（最新 2026-10-07）
```

```text
直したいこと 2件（うち要確認 1件、memory-audit-2026-11-02-103000-01〜）。未読の結果: repo-patrol 1件（2026-10-07）。失敗: memory-audit（2026-10-05 10:30。ログ <パス>）
失敗: skill-audit（2026-10-05 12:00。標準エラー <パス>）
```

- 未対応の変更があれば、件数・うち要確認の件数・最も古いIDを先頭へ出す。0件なら出さない。対応済みか見送りになるまで知らせる。
- 件数はSkill `change-review`の`scripts/count.sh`で数える。`CHANGE_REVIEW_SCRIPTS`、隣の`change-review/scripts`、`~/.claude/skills/change-review/scripts`の順に探す。見つからなければ、`lib.sh`が同じ記録から数える。
- 未読が1件のジョブは日付を、2件以上のジョブは最新の日付を添える。ジョブ名の順に並べる。
- 各ジョブの未読をすべて数える。古い未読が残っている間は件数に含まれ続けるので、読んだものは `mark-read.sh` で既読にする。
- 失敗は「失敗の判定」の規則で調べ、ジョブ名の順に並べる。日時は失敗の行のうち最も新しい時刻で、時刻の無い標準エラーの行だけのときはファイルの更新時刻を使う。ログと標準エラーの両方に失敗があれば両方のパスを出す。
- SessionStart フックで毎回動くため、外部コマンドの起動を回数の決まった少数に抑える。レポートの集計では既読の照合に awk を1回、直したいことの集計では記録をまとめて読む。失敗の判定では、既読の印より新しいログと標準エラーに限って awk などを起動する（test.sh で、200件のレポートに加え2000行のログと標準エラーを持つ3ジョブ、および2000件を超えるレポートと既読の記録を、それぞれ1.0秒以内に処理することを確かめている。しきい値は `REPORT_INBOX_TEST_TIME_LIMIT` で変えられる）。
- どんな失敗でも終了コード0で何も出さない。置き場所が無い、`lib.sh` が無い、既読の記録を読めない場合も同じである。

SessionStart フックへの登録は、リポジトリの `install.sh` が行う。手で登録するときの例（`settings.json` の `hooks`）:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$HOME/.claude/skills/report-inbox/scripts/unread.sh" } ] }
    ]
  }
}
```

## 失敗の判定

対象のジョブと、見るファイルは次のとおりである。ログは各ジョブが `<状態ディレクトリ>/logs/<YYYY-MM-DD-HHMMSS>.log` に1回の実行につき1つ書く。

| ジョブ | 状態ディレクトリ |
| --- | --- |
| feedback-mining | `$CLAUDE_REPORTS_STATE/feedback-mining` |
| memory-audit | `$CLAUDE_REPORTS_STATE/memory-audit` |
| repo-patrol | `$CLAUDE_REPORTS_STATE/repo-patrol` |
| secret-patrol | `$CLAUDE_REPORTS_STATE/secret-patrol` |
| skill-audit | `$SKILL_AUDIT_STATE` |

ジョブごとに、次のどちらかに当たれば失敗とする。

1. 最新のログ（名前の順で最後のもの）に `[YYYY-MM-DD HH:MM:SS] ERROR: ` で始まる行があり、その時刻が既読にした時刻より後である。
2. `<状態ディレクトリ>/launchd.stderr.log` に、既読にした時点より後に足された空でない行がある。時刻の書かれた ERROR の行は、時刻でも既読にした時刻と比べる。

既読の印より古いファイルは開かない。最新のログだけを見るため、失敗した実行の後に成功した実行があれば、前の失敗は知らせない。

### 除外する ERROR

`別の実行が進行中です` を含む行（二重起動の拒否）は、ログでも標準エラーでも失敗として数えない。前の実行が続いているだけで、運用上の問題ではないためである。各ジョブ（repo-patrol の `patrol.sh`、memory-audit と feedback-mining の `run.sh`、skill-audit の `run-audit.sh`）は、lock を取る処理（`mkdir "$LOCK_DIR"`）でこの行を出し、その後でログを開く（`exec >>"$LOG_FILE"`）。このため、実際には launchd の標準エラーにだけ現れる。

それ以外の ERROR（不明な引数、対象のディレクトリが無い、精査の異常終了、repo-patrol の「取得失敗」など）はすべて失敗として知らせる。

### 既読の記録

`$CLAUDE_REPORTS_STATE/report-inbox/failure-read/<ジョブ名>` に、1行目に既読にした時刻（`YYYY-MM-DD HH:MM:SS`）、2行目にその時点の標準エラーの行数を書く。標準エラーが切り詰められて行数が記録より少なくなったときは、先頭から数え直す。

## 直したいこと

記録は`$HOME/.local/state/claude-reports/changes/log.md`に置く。
`CLAUDE_REVIEW_CHANGES_LOG`で差し替えられる。
`## <日時> <ID>`から次の項目までを1件として読む。
`- 状態: 未対応`だけを数える。
`- 区分: 要確認（理由）`は、うち要確認の件数にも含める。
最も古い項目は記録の日時で求める。

`mark-read.sh`ではこの記録の状態を変えない。
会話のClaudeがSkill `change-review`の手順で入れ、`changes.sh mark`で対応済みか見送りにする。
旧来の`REPORTS_ROOT/proposals/*.md`は履歴として残し、集計しない。

## mark-read.sh

- 相対パスも受け付ける。レポートとして扱うもの以外を渡すと、エラーを出して記録しない（終了コード1）。ほかの引数の処理は続ける。
- 既に記録してあるものは重ねて書かない。
- 引数が無ければ終了コード2で終わる。
- `--failures` は全ジョブの、`--failure <ジョブ名>` は指定したジョブの失敗の知らせを既読にする。対象外のジョブ名は終了コード2で終わる。
- `--all` はレポートと失敗の知らせの両方を既読にする。レポートの置き場所が無くても、失敗の知らせは既読にする。

## list.sh

日付の新しい順、同じ日付では連番の大きい順に出す。`--unread` は未読のものだけを出す。

```text
repo-patrol / 2026-10-07 / <HOME>/claude-reports/repo-patrol/2026-10-07-2.md / 未読
```

`--failures` は未読の失敗をジョブ名の順に出す。ログと標準エラーを1件ずつ「ジョブ名 / 日時 / パス」で出し、続けて失敗の行を先頭3行まで字下げして出す。`--unread`・`--proposals` とは併用できない。

```text
memory-audit / 2026-10-05 10:31 / <HOME>/.local/state/claude-reports/memory-audit/logs/2026-10-05-103000.log
    [2026-10-05 10:31:05] ERROR: 精査が異常終了しました（終了コード 1）
```

`--changes`は未対応の変更を「ID / 直したいこと / 対象」の形で出す。`--proposals`も同じ意味で受け付ける。
`--unread`・`--failures`とは併用できない。

```text
会話-2026-11-02-01 / skill-auditの分割の表を直す / <HOME>/.claude/skills/skill-audit/SKILL.md
```
