# custom agentの挙動検証結果の形式

## 目的

custom agentの挙動検証について、対象definition、host条件、シナリオ、spawn attempt、execution、runtime分析、assessment、資源measurement、coverage、再実行条件を同じ単位で保持する。

## report

| 項目 | 内容 |
| --- | --- |
| `target` | agent名、対象host、候補componentごとのsource refとdigest、またはそれらを一意に固定するbundle digest。 |
| `validation_scope` | 対象契約、surface、親runtime、時間範囲、許可作用、停止条件、対象外。 |
| `contract_baseline` | 選択面、成果責務、入力、判断、行動、作用、成果、handoff、完了状態、停止条件、下位委譲方針。 |
| `scenarios` | 計画した各シナリオの契約。 |
| `spawn_attempts` | 親から開始した各attempt、結果、対応するexecution。 |
| `executions` | 成立したchild execution、follow-up、terminal state。 |
| `runtime_analysis_refs` | 各シナリオに対応するsubagentの実行分析結果への参照。 |
| `assessments` | シナリオと契約要素ごとの照合結果。 |
| `resource_measurements` | executionおよび計測範囲ごとのtoken使用量、経過時間、attempt、execution、respawn、tool call、課金額と根拠。 |
| `resource_measurement_status` | 必要な資源指標の取得状態。`complete`、`partial`、`unverified`。 |
| `efficiency_summary` | 同一比較条件の実行数、成立条件を満たす完了数、失敗または停止数、集約した資源使用、`cost per conforming completion`。 |
| `coverage` | 必須契約要素とシナリオの対応、runtime sourceの範囲、未実行または未解決の範囲。 |
| `validation_status` | `conforms`、`violates`、`unverified`、`in_progress`、`blocked`。 |
| `failures` | 直接確認した契約違反。 |
| `unverified` | identity、binding、設定、行動、成果、handoff、終了について断定できない命題。 |
| `rerun_scenarios` | 同じ入力で再実行するシナリオIDと、再実行前に変わる条件。 |

## scenario

各scenarioは次を持つ。

- `scenario_id`
- `required`: 必須なら `true`、任意なら `false`
- `execution_status`: `planned`、`running`、`terminal`、`blocked`
- `type`: `dispatch-selection`、`dispatch-non-selection`、`explicit-spawn`、`out-of-scope`、`configuration-and-effects`、`follow-up`、`terminal-or-stop`、`regression`
- `contract_refs`
- `required_candidate_components`
- `parent_request`
- `spawn_input`
- `initial_state`
- `allowed_effects`
- `follow_up_inputs`
- `expected_terminal_state`
- `stop_condition`
- `expected_observations`
- `required_runtime_evidence`
- `resource_measurement_plan`: 計測範囲、必要な指標、範囲ごとの経過時間の開始・終了event、token区分の意味と課金区分への対応、価格基準、反復条件、集約方法、比較対象となるexecutionの成立条件

期待する具体的な回答ではなく、契約から観測すべき選択、identity、設定、判断、行動、成果、handoff、状態を書く。

## execution binding

各scenarioについて、次をsubagentの実行分析結果へ対応付ける。

- parent taskまたはsession
- 時間範囲と端点の包含性
- spawn attempt ID
- child threadまたはexecution ID
- identity status
- agent origin
- definition binding IDsとstatus
- candidate componentごとの期待digest、対応binding ID、照合結果
- runtime effective configuration
- behavior/action observations
- resource measurement refs
- parent handoff
- terminal state

identity、agent origin、definition bindingを一つの確度へ集約しない。

候補componentの照合結果は `matched`、`mismatched`、`indeterminate` のいずれかとする。`matched` は、候補digestと一致する `exact` binding、または候補digestと一致する `time_correlated` bindingに対象hostのloadを示す追加根拠がある場合だけ使う。`current_only`、`unresolved`、digest不一致、追加根拠のない `time_correlated` は `matched` にしない。

## assessment

各assessmentは次を持つ。

- `scenario_id`
- `dimension`
- `setting`: 設定単位を評価する場合の名前。それ以外は `null`。
- `assessment`: `conforms`、`violates`、`indeterminate`、`in_progress`、`not_applicable`
- `contract_refs`
- `candidate_component_refs`
- `definition_binding_refs`
- `runtime_evidence_refs`
- `reason`
- `missing_evidence`

runtimeのterminal state、成果の存在、parentによる受領、契約適合を別のassessmentとして保持する。該当契約要素に必要な候補componentがexecutionへ結合されていない場合、そのassessmentを `conforms` または `violates` にせず `indeterminate` とする。

## resource measurement

各measurementは次を持つ。

- `scenario_id`
- `execution_ref`、またはparentとend-to-endを表すscope ref
- `scope`: `child`、`descendants`、`parent`、`end_to_end`
- `metric`: runtimeが報告するtoken区分、`elapsed_time`、`spawn_attempts`、`started_executions`、`respawns`、`tool_calls`、`provider_reported_cost`、`derived_cost`
- `value`、取得できない場合は `null`
- `unit`
- `claim_kind`: `observed`、`derived`、`unverified`
- `evidence_refs`
- `calculation`: 導出値の場合の式、入力measurement、価格基準への参照
- `missing_reason`

runtimeが報告するtoken区分は名称と値をそのまま保持する。入力、出力、cache、reasoning、totalなど、runtimeが区別しない区分を推定で作らない。`provider_reported_cost` は課金記録の値、`derived_cost` は観測した使用量と時点付き価格基準から計算した値として別measurementにする。価格基準はprovider、modelまたは課金区分、通貨、単価、適用時点、source refを持つ。導出費用の計算には、各usage metricが課金区分の総量、内数、または独立量のどれに対応するかを示すmappingを使う。mappingを確認できないtoken区分を含む導出費用は `unverified` とする。

経過時間は資源計測条件が範囲ごとに定めた開始と終了または停止のevent ref、端点の包含性、計測範囲を保持する。両端を指定または観測できない範囲の経過時間は `unverified` とする。parent、child、descendants、end-to-endを一つの時間または費用へ暗黙に集約しない。

`resource_measurement_status=complete` は資源計測条件で必要とした各指標を値または適用外として確定できた場合、`partial` は一部を取得し一部が `unverified` の場合、`unverified` は比較に必要な指標をexecutionへ結合できない場合に使う。

## efficiency summary

各summaryは、同じシナリオ、委譲入力、初期状態、許可作用、親runtime、計測範囲、停止条件、反復条件に対応するvalidation recordだけを集約する。次を持つ。

- 比較条件と対象record refs
- 集約方法
- 全attempt数と開始済みexecution数
- 成立条件を満たす完了数
- timeout、blocked、契約不適合、その他の非成立数
- 指標ごとの集約値とmeasurement refs
- `cost_per_conforming_completion`: 全attemptの費用合計、成立条件を満たす完了数、導出式、価格基準refs。完了数がゼロの場合は `null` と理由

efficiency summaryは資源効率の比較材料であり、候補の採否またはmodel選択を表さない。

## coverage

coverageは、必須契約要素ごとに対応するscenario、必要な候補component、spawn attempt、成立したexecution、identityとbindingの状態、assessmentを示す。資源計測については必要な指標、計測範囲、対応するruntimeまたは課金source、measurement statusを示す。全体を `conforms` にできるのは、各必須契約要素に必要な候補componentが対応executionへ `matched` で結合されている場合だけとする。runtime sourceの完全性を確認できない範囲では、全attempt、全execution、または全資源使用を取得したと断定しない。

## 再実行

`rerun_scenarios` は、失敗、未確認、継続中、blockedのシナリオと、候補変更の影響が届く回帰シナリオを示す。各項目に、同じまま保持する委譲入力と、再実行前に変わるdefinition、binding、親runtime、実行条件、証拠取得条件を含める。
