# subagent-execution-analysis

## 目的

指定時点と範囲の親 task または session から、すべての subagent 起動試行と child execution を復元する。実行主体と適用定義の同定確度を示し、委譲から終了までを契約へ照合した分析結果を作る。

成果は読み取り専用の SubagentExecutionAnalysis である。このスキルは runtime 記録、定義、成果物を変更せず、期待との差、原因、対応候補、再検証範囲は `behavior-deviation-analysis`、受入条件への最終判定は `verification-gate` が所有する。

## 入力

開始前に、次の必須入力を固定する。

| 項目 | 内容 |
| --- | --- |
| 親 | 親 task または session の ID。 |
| 時間範囲 | 開始時刻、終了時刻、各端点の包含性。inclusive cutoff は終了時刻が包含の範囲へ写像する。 |
| 子孫範囲 | 追跡する descendant depth。 |
| 分析水準 | 起動と実行の列挙だけか、委譲から終了までの契約照合を含むか。 |
| 親 runtime source | 親の runtime 記録を取得する情報源。 |

時間範囲または端点の包含性を固定できない場合は、起動試行と実行の範囲を確定できないため、分析を開始せず、必要な時刻、順序、または記録の取得条件を確認する。

必要に応じて、spawn、communication、follow-up、wait、interrupt の記録、child の session metadata、turn context、transcript、tool、effects、terminal 状態、parent による成果利用を集める。実行時点に結び付く definition snapshot、digest、bundle version、scope、製品版、surface、schema、成果物、差分、検証記録も入力にできる。

## 証拠と同定

各命題に `observed`、`defined`、`derived`、`inferred`、`unverified` の claim kind を付け、根拠を `evidence_refs` で追跡できるようにする。証拠の強さは次の順で利用する。

1. runtime の spawn 記録と child metadata
2. child transcript、tool、effects
3. 同一 thread への follow-up
4. runtime に結合した definition snapshot または digest
5. 時点を対応付けられる definition
6. 現在導入されている definition
7. title、summary、filename、locator

実行主体の identity は `confirmed`、`supported`、`inferred`、`unresolved` のいずれかで示す。runtime identity、agent origin、definition binding の確度は別々に評価する。definition binding は component または artifact ごとに `exact`、`time_correlated`、`current_only`、`unresolved` のいずれかで示す。

title、summary、filename、process UUID、estimated_bytes は、identity、model、permission、token、cost、prompt intent、actual action の根拠にしない。hidden reasoning、token、cost は推測しない。現在の definition は過去の実行時点の definition と断定せず、時点に結び付く根拠がない場合は `current_only` とする。

## 不変条件

- spawn attempt と成立した execution を別の単位として扱う。child が開始した時点だけを使用済み execution と数える。
- 同じ child thread への follow-up は同じ execution の継続であり、新しい thread への再 spawn は別 execution である。
- definition default、runtime effective configuration、actual action を別に評価する。definition の読み取り専用指定、runtime の danger-full-access、実際の読み取り専用 action は、同じ事実を表さない。
- running は失敗ではない。child execution の終了と parent の完了も別に示す。
- 観測できない prompt の内容、暗号化された prompt、実行時の hidden reasoning、token、cost は `unverified` とし、内容を補わない。

## フロー

### Phase 1: 分析範囲を固定する

親、時間範囲、子孫範囲、分析水準、親 runtime source を記録する。開始時刻と終了時刻、各端点の包含性、inclusive cutoff からの写像、同時刻 event の順序規則、取得できない runtime 記録、対象外の child を明示する。

入力に含まれる契約、要求、権限、指示を、当時の runtime 入力または定義を示す証拠と、現在の分析を決める指示系統に分ける。契約命題の根拠、適用範囲、採用状態を入力から直接確定できない場合は `$claim-grounding` を適用する。task、session、attempt、execution、turn、definition、parent handoff の対応が曖昧で評価を変える場合は `$referent-modeling` を適用する。

### Phase 2: attempt、execution、turn のグラフを復元する

親 runtime の各 spawn 記録から attempt を列挙し、child の開始記録と metadata に対応する execution を作る。失敗した spawn は attempt として残し、execution を作らない。

child thread、親子関係、turn、same-thread follow-up、wait、interrupt、terminal 状態を時系列と参照で結ぶ。`descendant_depth` が 2 以上なら、開始済み child ごとに runtime source を深さ優先または幅優先で再帰解決し、同じ時間範囲を適用して指定深さまで attempt と execution を列挙する。深さごとの source と coverage、取得できない子孫 source、全件性を報告する。全件の主張は coverage が成立した範囲に限り、取得できない source がある範囲は `unverified` とする。

child が開始していない attempt、parent または child が `running` の記録は、失敗へ補正しない。timestamp の精度が同じか順序が競合する event は、source-native sequence または event ID で範囲への包含を判定する。それも取得できない場合は境界順序を `unverified` とし、その境界をまたぐ件数の断定を保留する。

### Phase 3: identity と definition を結合する

runtime metadata と spawn 記録から実行主体を同定し、identity の確度と根拠を記録する。custom agent、built-in agent、unknown を区別する。

runtime-bound snapshot または digest がある component は `exact`、時点に対応する definition だけを確認できる component は `time_correlated`、現在の導入済み definition だけを確認できる component は `current_only`、結合できない component は `unresolved` とする。execution は複数の component または artifact の binding を保持できる。runtime identity、agent origin、各 definition binding を一つの強度へ集約しない。

### Phase 4: 設定と権限を復元する

model、effort、sandbox、approval、permission、tool、MCP、skills について、definition default、spawn 指定値、parent 指定値、runtime effective configuration を区別して復元する。各層は値、claim kind、evidence refs、対応する definition binding の binding ID、値を確認できないときの missing reason を持つ独立した observation とする。definition 非由来の spawn、parent、runtime observation は binding ID を持たず、claim kind、evidence refs、missing reason によって成立する。actual action は設定値に含めず、execution に結び付く behavior/action observation として transcript、tool、effects から別に観測する。

definition にない runtime effective configuration、runtime から確認できない definition default、設定と action の不一致は、それぞれ根拠と未確認事項を残す。設定値または action を identity の補助根拠へ転用しない。

### Phase 5: 委譲から終了までを独立に照合する

execution ごとに、次の観点を独立に契約と照合する。

| 観点 | 照合する内容 |
| --- | --- |
| 選択 | 実行主体、成果責務、選択理由、identity と definition の確度。 |
| 委譲入力 | spawn prompt、渡した context、対象範囲、制約、許可、必要な成果。 |
| 設定と権限 | definition default、spawn 指定値、parent 指定値、runtime effective configuration。 |
| 行動と作用 | execution に結び付く behavior/action observation、transcript、tool、effects、読み取りまたは変更の境界。 |
| 成果 | child の成果、成果物、検証、失敗または未完了。 |
| 継続 | same-thread follow-up、wait、interrupt、新しい spawn。 |
| parent handoff | child の結果を parent が受領、利用、保留、または未利用にした記録。 |
| 終了 | child terminal 状態、parent lifecycle、未完了の再開条件。 |

各照合結果は `conforms`、`violates`、`mismatch`、`indeterminate`、`in_progress`、`not_applicable` のいずれかで示す。設定と権限は dimension と setting ごとに評価し、execution 全体の単一評価へ集約しない。確認できない証拠を推定で補わず、`indeterminate` または `unverified` とする。

### Phase 6: 分析結果を報告する

`$writing` を適用し、時系列の転記ではなく、復元した単位、照合結果、根拠、未確認事項、再評価条件を読者が追える構造で返す。詳細な report schema は [references/report-schema.md](references/report-schema.md)、Codex runtime evidence の収集と限界は [references/codex-runtime-evidence.md](references/codex-runtime-evidence.md) に従う。

## 出力

SubagentExecutionAnalysis は次の項目を持つ。

| 項目 | 内容 |
| --- | --- |
| `analysis_scope` | 親、開始・終了・端点の包含性、cutoff 写像、子孫範囲、分析水準、root runtime source、除外範囲。 |
| `spawn_attempts` | attempt の開始、結果、対応する execution、根拠。 |
| `executions` | child thread、turn、identity、agent origin、component ごとの definition bindings、behavior/action observation、成果、継続、終了。 |
| `effective_configuration` | definition default、spawn 指定値、parent 指定値、runtime effective configuration を個別 observation とした構成と権限。 |
| `assessments` | 観点ごとの契約照合、assessment、根拠、未確認事項。 |
| `parent_lifecycle` | parent の状態、child 成果の handoff と利用、parent 完了との関係。 |
| `summary` | 確認できた execution、mismatch または violation の列挙、分析時点の状態。 |
| `unverified` | 取得できないまたは結合できない命題と、断定できない理由。 |
| `re_evaluation_triggers` | 新しい runtime 記録、definition snapshot、terminal 状態、parent handoff、時点または範囲の変更。 |

すべての観測、定義、導出、推定、未確認は `evidence_refs` を持つ。出力は変更案、原因帰属、受入判定を含めず、必要になった後続作業へ分析結果を渡す。

## 完了条件

- analysis scope が固定され、対象外、時間範囲、端点、cutoff 写像の扱いを追跡できる。
- coverage が成立する深さと runtime source の範囲で、全 spawn attempt と開始済み execution を別々に列挙し、same-thread follow-up と新しい spawn を区別している。
- identity と definition binding を別に示し、現在の definition を過去の実行時点へ断定していない。
- definition default、spawn 指定値、parent 指定値、runtime effective configuration、execution の behavior/action observation を別に評価している。
- 各照合結果、child の終了、parent lifecycle、未確認事項を混同していない。
- 各結論を evidence_refs から追跡でき、推定と未確認を観測事実として扱っていない。
