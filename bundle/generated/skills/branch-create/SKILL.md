# branch-create

## 目的
作業内容、Issue、指定値から規約準拠の作業ブランチを確定し、現在作業を失わず対象 worktree をそのブランチへ接続する。

既存ブランチがある場合は再利用する。
新しい作業を既定ブランチから始める場合は、fetch 後の既定ブランチの OID を起点にする。

## フロー

### Phase 1: 作業状態を確認する
- ユーザーが指定した worktree、または作業開始時の worktree root の絶対パスを対象として固定する。
- `gh auth status` を確認する。
- `origin`、開始時の `HEAD` OID、ブランチまたは detached HEAD、未コミット差分、未解決の競合、worktree 使用状況を確認する。
- Issue が指定されている場合は `gh issue view` で存在と状態を確認し、open でなければ停止する。
- 未解決の競合がある場合は、ブランチを作成または切り替えず停止する。

### Phase 2: 起点を決める
base branch が指定されていれば採用する。
未指定ならリポジトリの既定ブランチを採用する。
`git fetch origin --prune` を実行し、base branch を fetch 後の remote-tracking ref と commit OID に解決する。
この fetch は新しいブランチの起点を確定するために行い、接続済みブランチへの同期は Phase 4 で `$sync-latest` に委譲する。
fetch または base branch の解決に失敗した場合は停止する。

次のいずれかに該当する場合は、現在作業を保持するため開始時の `HEAD` を起点にする。

- ユーザーが現在の `HEAD` を起点として指定した。
- 未コミット差分がある。
- detached HEAD であり、開始時の `HEAD` が fetch 後の base OID の祖先でない。

それ以外は fetch 後の base OID を起点にする。

detached HEAD が clean で、開始時の `HEAD` が fetch 後の base OID の祖先である場合は、古い `HEAD` ではなく base OID から新しいブランチを作成する。
detached HEAD の独自 commit または未コミット差分を保持する場合は、開始時の `HEAD` にブランチを付けてから `$sync-latest` を実行する。
ブランチを付ける前に detached HEAD の commit、差分、履歴を書き換えない。

### Phase 3: ブランチ名を決める
ブランチ種別が指定されていれば採用する。
指定がなければ Issue、ユーザー指示、差分の目的から一般的な開発語彙に沿って選ぶ。

| 変更の性質 | branch type | 対応する Conventional Commit type |
| --- | --- | --- |
| 利用者に見える機能追加 | `feature` | `feat` |
| バグ修正 | `fix` | `fix` |
| 振る舞いを変えない構造整理 | `refactor` | `refactor` |
| 性能改善 | `perf` | `perf` |
| テスト | `test` | `test` |
| ドキュメント | `docs` | `docs` |
| CI 設定 | `ci` | `ci` |
| build、依存、リリース設定 | `build` | `build` |
| その他の保守作業 | `chore` | `chore` |

判断できない場合は `chore` を使う。

ブランチ名が指定されていれば slug 化して使う。
未指定なら Issue、ユーザー指示、差分の目的から slug を作る。

Issue がある場合は `<type>/issue-<N>-<branch_name>` にする。
Issue がない場合は `<type>/<branch_name>` にする。

slug は ASCII 小文字、数字、ハイフンで構成する。
空になった場合は `goal` を使う。

### Phase 4: ブランチを作成または再利用する
- 現在ブランチが確定名と一致する場合は再利用する。
- 同名ローカルブランチがある場合は、別 worktree で使用中でないことを確認して再利用する。
- 既存ブランチが別 worktree で使用中なら停止する。
- 保持すべき開始時の `HEAD` を再利用するローカルまたは remote branch が含まない場合は、そのブランチへ切り替えず停止する。
- `origin/<確定ブランチ名>` がある場合は、fetch 後の ref と OID を記録する。
- 同名ローカルブランチと `origin/<確定ブランチ名>` の両方がある場合は、upstream が未設定ならその remote-tracking branch を設定して再利用する。同じ upstream が設定済みなら維持し、別の upstream が設定されていれば切り替えず停止する。
- 同名ローカルブランチがなく、`origin/<確定ブランチ名>` がある場合は tracking branch として再利用する。
- 既存ブランチがなければ、Phase 2 で確定した commit OID から作成する。
- fetch 後の base OID から新しい作業ブランチを作る場合は、base branch を upstream に設定しない。

作成または再利用したブランチへ、Phase 1 で固定した対象 worktree を接続する。
対象 worktree が確定ブランチへ接続された後で、Phase 2 の remote-tracking ref を指定ブランチとして `$sync-latest` へ渡す。
`$sync-latest` が再度 fetch した後の指定ブランチ OID を最終的な base OID とし、upstream とその base との同期を確認する。
未コミット差分の保護が必要なため `$sync-latest` が停止した場合は、ブランチ作成の完了と同期の未完了を分けて報告する。

### Phase 5: 完了状態を確認する
次を満たした場合だけ、ブランチの作成または再利用が完了したと判断する。

- Phase 1 で固定した対象 worktree の現在ブランチが確定名と一致する。
- 現在作業を保持する経路では、開始時の `HEAD` が最終 `HEAD` の祖先であり、開始時の未コミット差分が保持または commit されている。
- base の同期まで完了した場合は、`$sync-latest` が再 fetch 後に確定した base OID が最終 `HEAD` の祖先である。
- `origin/<確定ブランチ名>` を再利用した場合は、その再 fetch 後の OID が最終 `HEAD` の祖先であり、upstream が同じ remote-tracking branch である。
- 新規作業ブランチが base branch を upstream にしていない。
- 未解決の競合がない。

別の clone や worktree に確定名のブランチが存在するだけでは、対象 worktree の完了とは判断しない。

### Phase 6: 状態を残す
対象 worktree の絶対パス、確定したブランチ名、起点の ref と OID、作成または再利用の結果、開始時の作業を保持した方法、同期の完了または未完了、停止理由を残す。
