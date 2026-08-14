# Skillの挙動検証結果の形式

## 目的

Skillの挙動検証について、対象、比較基準、シナリオ、実行、assessment、coverage、再実行条件を同じ単位で保持する。

## claim kind

各命題を次のいずれかで示す。

| 値 | 意味 |
| --- | --- |
| `observed` | 実行、成果物、tool、runtime記録から直接確認した。 |
| `defined` | 権限ある契約または対象定義に記載されている。 |
| `derived` | 確認済みの複数命題から手順を示して導出した。 |
| `inferred` | 直接確認できず、限定された状況証拠から推定した。 |
| `unverified` | 判定に必要な根拠を取得できない。 |

`inferred` をselectionまたはSkill利用の成立証拠にしない。

## report

| 項目 | 内容 |
| --- | --- |
| `target` | Skill名、候補componentごとのsource ref、digest方式と値、またはそれらを一意に固定するbundle digest。 |
| `validation_scope` | 対象契約、利用場面、実行環境、許可作用、停止条件、対象外。 |
| `contract_baseline` | 検証する責務、発火面、入力、判断、行動、成果、完了状態と根拠。 |
| `scenarios` | 計画した各シナリオの契約。 |
| `executions` | 実際に開始した実行と観測。 |
| `assessments` | シナリオと契約要素ごとの照合結果。 |
| `coverage` | 必須契約要素とシナリオの対応、実行済み範囲、未実行範囲。 |
| `validation_status` | `conforms`、`violates`、`unverified`、`in_progress`、`blocked`。 |
| `failures` | 直接確認した契約違反。 |
| `unverified` | 証拠不足により断定できない命題。 |
| `rerun_scenarios` | 同じ入力で再実行するシナリオIDと、再実行前に変わる条件。 |

## scenario

各scenarioは次を持つ。

- `scenario_id`
- `required`: 必須なら `true`、任意なら `false`
- `execution_status`: `planned`、`running`、`terminal`、`blocked`
- `type`: `explicit-use`、`natural-selection`、`non-selection`、`decision-branch`、`stop-or-unverified`、`regression`
- `contract_refs`
- `required_candidate_components`
- `request`
- `initial_state`
- `allowed_effects`
- `stop_condition`
- `expected_observations`
- `required_evidence`

期待する結論や具体的な回答ではなく、契約から観測すべき選択、判断、行動、成果、状態を書く。

## execution

各executionは次を持つ。

- `scenario_id`
- `execution_ref`
- `started_at`
- `stopped_at`
- `terminal_state`
- `selection_observations`
- `candidate_component_observations`
- `behavior_observations`
- `effects`
- `artifacts`
- `evidence_refs`

`terminal_state` と契約適合を同じ値へ集約しない。

## assessment

各assessmentは次を持つ。

- `scenario_id`
- `dimension`
- `assessment`: `conforms`、`violates`、`indeterminate`、`in_progress`、`not_applicable`
- `contract_refs`
- `candidate_component_refs`
- `evidence_refs`
- `reason`
- `missing_evidence`

評価に必要な候補componentをexecutionへ結び付けられない場合、そのassessmentを `conforms` または `violates` にせず `indeterminate` とする。

## coverage

coverageは、必須契約要素ごとに対応するscenario、必要な候補component、実行状態、assessmentを示す。全体を `conforms` にできるのは、各必須契約要素に必要な候補componentが対応executionへ結び付いている場合だけとする。シナリオ数や実行数だけから完全性を導出しない。自然選択の直接記録を取得できない場合は、その検証面を未検証範囲として残す。

## 再実行

`rerun_scenarios` は、失敗、未確認、継続中、blockedのシナリオと、候補変更の影響が届く回帰シナリオを示す。各項目に、同じまま保持する入力と、再実行前に変わるdefinition、実行条件、証拠取得条件を含める。
