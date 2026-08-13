## Codex runtime evidence

### 対象単位

分析では、親 task または session、spawn attempt、開始済み child execution、child thread、turn、follow-up、definition、parent handoff を別の対象として扱う。locator は対象を探す手掛かりであり、対象の identity、設定、prompt intent、actual action の証拠ではない。

| 対象 | 直接観測として使える例 | 単独では確定しないこと |
| --- | --- | --- |
| spawn attempt | 親 runtime の spawn 要求、時刻、宛先、結果。 | child が開始したこと、child の terminal 状態。 |
| execution | child metadata、開始 event、child thread ID。 | 適用した definition version。 |
| follow-up | 同じ child thread に配送された継続入力。 | 新しい execution の開始。 |
| runtime configuration | runtime event または child metadata に記録された effective model、effort、sandbox、approval、permission、tool、MCP、skills。 | definition default、actual action。 |
| actual action | child transcript、tool call、effect、成果物または外部状態の観測。 | 許可された全作用、hidden reasoning、token、cost。 |
| resource usage | executionへ対応するruntime使用量、開始・終了event、providerの課金記録。 | runtimeが報告しないtoken区分、hidden reasoningの内容、executionへ対応付けられない費用。 |
| definition | runtime-bound snapshot、digest、bundle version、scope、時点と対応する定義。 | runtime がその定義を実際に適用したこと。 |
| parent handoff | 親 transcript、受領記録、child 結果への参照、後続入力。 | 暗号化または欠落した child 成果の成果契約への適合。 |
| parent lifecycle | 親 runtime の terminal event または `task_complete`。 | 成果契約が成功したこと。 |

### identity と definition binding

親 spawn と child runtime metadata が、同じ parent、child、role を示す場合だけ identity を `confirmed` とする。片側の runtime 記録だけがあり、同じ identity に競合する記録がない場合は `supported` とする。両側の runtime 記録があっても必須 tuple の一部が欠ける場合、少なくとも一方が execution を一意に同定し、他方と競合しなければ `supported` とする。どちらも execution を一意に同定できない、または記録が競合する場合は `unresolved` とする。path、title、summary、content だけから対応付ける場合は `inferred` 以下とし、対応を確定しない。

agent origin は identity confidence と独立した observation とする。runtime origin marker がない場合は `custom` を断定せず、value は `unknown`、claim kind は根拠に応じて `inferred` または `unverified` とする。origin が `unknown` でも、現在の definition は比較候補として `current_only` にできる。ただし、これは runtime がその definition を実行時に適用した証拠ではない。

parent が child 成果を受領または利用した記録は handoff の assessment を支える。child 成果が暗号化または欠落している場合、その記録だけで成果契約への適合を導かない。

### handoff coverage

handoff coverage は、parent 側の handoff に関係する transcript、communication、result records を、指定時間範囲で source 固有の完全性保証とともに確認して評価する。`complete` は、これらの records が時間範囲を網羅し、範囲内の各 started execution に handoff event またはその不在を対応付けられる場合だけ成立する。既知の record 欠落または execution への対応付け欠落は `partial`、完全または部分を判定する source 保証がない場合は `unverified` とする。

### 時点と状態

時間範囲は `start`、`end`、`start_inclusive`、`end_inclusive` を固定して比較する。inclusive cutoff は `end=cutoff` と `end_inclusive=true` へ写像する。たとえば `20:00:09Z` を inclusive cutoff とした記録に researcher2 と architect1 だけがある場合、両者をその時点の範囲へ含める。architect と parent が `running` なら、どちらも失敗ではなく `in_progress` とする。`20:04:17Z` 後に reviewer の spawn が確認できる場合は、その後の範囲に reviewer attempt と execution を追加する。

event timestamp の精度が同じ、または timestamp による順序が競合するときは、同じ source が記録した native sequence または event ID を優先して境界の包含を決める。どちらも利用できない場合は、境界順序を `unverified` とし、その境界をまたぐ attempt または execution の件数を確定しない。

同じ architect thread への follow-up は同じ execution の追加 turn として結び、新しい child thread の spawn は別 execution とする。failed spawn は attempt だけとして残し、使用済み execution 数に加えない。

### 子孫 runtime source

root runtime source は深さ 0 とし、開始済み child の runtime source は child execution に対応する深さ 1 以上の source とする。指定 depth 未満の execution ごとに child source を解決し、同じ時間範囲を適用して探索する。深さ優先と幅優先は、source、時間範囲、重複排除、coverage を同じくする限り、同じ分析結果を作る手段として選べる。

source を取得できない、child と source の対応を確認できない、または時間範囲の境界を確定できない場合は、その source と影響する descendant 範囲を `unverified` にする。`complete_within_coverage` の三値と全件数の扱いは [report schema](report-schema.md) に従う。

runtime source の十分性は、支える claim、dimension、coverage ごとに評価する。特定の API または工具の欠如だけで一律に不成立とせず、同等の一次 runtime records が identity link、時間範囲、coverage を支える範囲は採用する。不足する面だけを `indeterminate` または `unverified` とし、普遍的な必須ツール集合を固定しない。

### 設定と action の分離

definition が read-only を定め、runtime effective configuration が danger-full-access で、child transcript に読み取り action だけがある場合、設定の二つの observation と execution の behavior/action observation をそれぞれ記録する。この例では definition と runtime の不一致を評価できるが、actual action が読み取りだったことから runtime permission を読み取り専用と結論付けない。

prompt が暗号化されていて内容を観測できない場合、prompt 内容は `unverified` とする。title、summary、filename、process UUID、estimated_bytes、現在の TOML 一致は、過去の definition binding を `exact` にする根拠ではない。

tool または effect trace が不完全な場合、確認できた behavior/action observation には限定した assessment を付けられる。execution 全体の action coverage と assessment は別にし、未観測範囲が結果を変え得る場合は全体を `indeterminate` とする。

runtime使用量はexecutionまたは計測範囲へ対応するrecordだけを直接観測として使う。token区分はsourceの名称、値、区分間の関係を保持する。資源計測範囲が定めた開始・終了・停止eventから経過時間を導出し、使用したevent refsと端点を残す。課金額はproviderの課金記録を直接観測とし、token使用量から算出する場合はusage metricと課金区分のmapping、時点付き価格基準を別の根拠として保持する。

child の `task_complete` は `terminal_state` の観測値として execution に記録する。outcome と成果への適合は別の observation と assessment であり、product contract の追加根拠がない限り、`task_complete` 単独から成功を導かない。
