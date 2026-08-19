# slack-context-reader

## 目的

指定されたSlackの会話範囲を取得し、Slackから確認した事実、取得範囲、未取得範囲、再開条件を返す。

## 入力

- workspaceと、今回使うSlack appまたは認証主体
- 読み取り方式
- 対象または探索範囲
- message、thread、期間、件数、添付などの要求範囲

| 読み取り方式 | 入力 | 成果 |
| --- | --- | --- |
| `direct_reference` | Slack URL、conversation ID、message ID、thread参照 | 正規化した対象と現在状態 |
| `discovery` | conversation、actor、検索語、期間 | 条件に合う候補と探索済み範囲 |

Slack URLだけが入力された場合は、URLからworkspaceと対象を正規化する。ローカルCLIの現在の認証選択が一つでworkspaceと一致する場合は、その選択を今回の認証主体として固定する。それ以外は `input_incomplete` とする。

## 取得

取得経路は、ローカルSlack CLIの `slack api` とする。最初の取得前に、CLIが選択しているworkspace、Slack app、認証主体を確定する。methodと引数は、インストール済みCLIのhelpと現在のSlack公式資料から選ぶ。

`direct_reference` では、workspace、conversation、親message、thread、対象messageを正規化する。`discovery` では、conversation、actor、検索語、期間と候補条件を固定する。

要求範囲を満たすか、取得を継続する条件が未成立になるまで、必要なmessage、reply、actor、reaction、file参照、attachment、unfurlとpaginationを取得する。

- 親messageとthread replyの関係を保持する。
- message ID、actor、時刻、本文、blocks、編集、reaction、mention、broadcastを要求範囲に応じて保持する。
- Slack file、message attachment、unfurl、message内リンクを別の対象として記録する。
- Slackリンク先は、要求範囲に必要な場合に取得対象へ加え、元messageとの関係を保持する。

## 結果

結果には次を含める。

- 元参照または探索条件
- workspace、conversation、親message、thread、messageの識別子
- 取得時刻と、各取得に使ったmethod
- 取得したmessages、actors、reactions、file参照、attachments、unfurls
- 要求範囲、取得済み範囲、未取得範囲、pagination
- 認証、権限、rate limit、対象不在などの付帯条件と再開条件

認証情報はworkspace、Slack app、actorの識別子までを成果に含める。

主状態は、取得終了時の状態から次の順で一つ選ぶ。併存する事実は付帯条件に保持する。

| 状態 | 成立条件 |
| --- | --- |
| `not_found_confirmed` | `direct_reference` の対象が存在し得る範囲を完全取得し、対象がなかった |
| `complete` | 要求範囲とpaginationを取得し、対象または探索結果を返した |
| `input_incomplete` | 対象、範囲または認証主体が未確定で、Slackへの取得要求を開始していない |
| `rate_limited` | 有効なrate limitの再開条件が要求範囲の取得を止めている |
| `access_unconfirmed` | 認証、workspace、scopeまたは対象へのアクセス確認が要求範囲の取得を止めている |
| `partial` | その他の取得失敗またはpagination中断により未取得範囲が残る |

`discovery` が `complete` で候補が空の場合は、指定した探索範囲で一致がなかったことを成果とする。`channel_not_found`、`not_authed`、`missing_scope` などの応答は付帯条件として保持し、表の条件から主状態を選ぶ。

## 完了条件

- Slackから確認した事実を、method、対象、取得時刻へ追跡できる。
- 要求範囲、取得済み範囲、未取得範囲、paginationが対応している。
- 主状態と付帯条件から、完了または再開に必要な条件を判断できる。
