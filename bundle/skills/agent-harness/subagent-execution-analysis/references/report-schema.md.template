## subagentの実行分析結果の形式

subagentの実行分析結果はJSON、表、または構造化した文章で表現できる。表現形式にかかわらず、各項目は `evidence_refs` と、該当する場合は `claim_kind`、identity confidence、definition binding、assessment、unverified reason を保持する。

```text
analysis_scope
  parent_id, time_range { start, end, start_inclusive, end_inclusive }
  cutoff_mapping | null, descendant_depth, analysis_level
  root_runtime_source, exclusions, evidence_refs
coverage[]
  depth, runtime_source_ref, source_status, time_range_status
  complete_within_coverage { value: true | false | null, claim_kind, evidence_refs, missing_reason }
  affected_descendant_range, evidence_refs
spawn_attempts[]
  attempt_id, parent_id, occurred_at, requested_subject, outcome
  execution_ref | null, claim_kind, evidence_refs
executions[]
  execution_id, attempt_ref, child_thread_id, turns[]
  identity { subject, confidence, evidence_refs }
  agent_origin { value: custom | built_in | unknown, claim_kind, evidence_refs, missing_reason }
  definition_bindings[]
    binding_id, component
    definition_ref { value, claim_kind, evidence_refs, missing_reason }
    definition_digest { value, claim_kind, evidence_refs, missing_reason }
    binding_status { value, claim_kind, evidence_refs, missing_reason }
  behavior_action_observations[] { kind, value, claim_kind, evidence_refs, missing_reason }
  behavior_action_coverage { assessment, evidence_refs, missing_reason }
  outcome { value, claim_kind, evidence_refs, missing_reason }
  terminal_state { value, claim_kind, evidence_refs, missing_reason }
resource_usage[]
  scope { kind: child | descendants | parent | end_to_end, refs[] }
  metric, value | null, unit
  claim_kind { observed | derived | unverified }, evidence_refs, missing_reason
  calculation { formula, input_measurement_refs[], pricing_ref | null } | null
pricing_basis[]
  pricing_ref, provider, model_or_billing_class, currency, rates, effective_at
  usage_mapping[] { usage_metric, relation: total | subset | independent, billing_class }
  source_ref, claim_kind, evidence_refs, missing_reason
effective_configuration[]
  execution_ref, setting
  definition_default { value, binding_refs[]: binding_id, claim_kind, evidence_refs, missing_reason }
  spawn_value { value, binding_refs[]: binding_id, claim_kind, evidence_refs, missing_reason }
  parent_value { value, binding_refs[]: binding_id, claim_kind, evidence_refs, missing_reason }
  runtime_effective { value, binding_refs[]: binding_id, claim_kind, evidence_refs, missing_reason }
assessments[]
  execution_ref, dimension, setting | null
  contract_ref { value, claim_kind, evidence_refs, missing_reason } | null
  missing_evidence { value, claim_kind, evidence_refs, missing_reason } | null
  assessment, scope { behavior_action_observation_ref | execution }
  rationale, evidence_refs, unverified_refs
parent_lifecycle
  parent_state, task_complete { value, claim_kind, evidence_refs, missing_reason }
  child_handoffs[] { execution_id, kind, state, occurred_at, claim_kind, evidence_refs, missing_reason }
  handoff_coverage { value: complete | partial | unverified, claim_kind, evidence_refs, missing_reason }
  completion_relation, evidence_refs
summary
unverified[]
  subject, reason, required_evidence, evidence_refs
re_evaluation_triggers[]
  trigger, affected_items, expected_evidence
```

`coverage` は深さごとの source 取得、child との対応付け、時間範囲判定の成立範囲を記録する。`complete_within_coverage.value` は、source 固有の完全性保証が時間範囲の event 全件を覆い、指定 depth 内の各 started child runtime source が解決・走査済みの場合だけ `true` とする。観測された欠落または未解決 child source により coverage 不完全が直接確認できる場合は `false` とする。完全または不完全のどちらも確定できない場合は `null` とし、`claim_kind=unverified` と `missing_reason` を残す。`true` 以外では全件数を断定しない。

`effective_configuration` の各層は独立した observation であり、値が存在しない場合も `missing_reason` と `claim_kind=unverified` を持つ。actual action は設定の observation ではなく、`executions[].behavior_action_observations` にだけ記録する。

`definition_bindings` は execution 内で一意な `binding_id` を持つ、component または artifact ごとの binding を保持する。`definition_ref`、`definition_digest`、`binding_status` は独立した observation であり、digest が欠けても ref または status の確度を下げない。たとえば適用 instructions を `exact`、host 設定を `time_correlated`、現在の TOML を `current_only` と同じ execution に併記できる。`effective_configuration` の各 observation は `binding_refs` で対応する `binding_id` だけを参照する。definition 非由来の spawn、parent、runtime observation は `binding_refs=[]` を許容し、その observation 自体は claim kind、evidence refs、missing reason によって成立する。

`contract_ref` は比較契約がある場合の evidence-bearing reference である。比較契約が適用されない場合は `contract_ref=null` と `assessment=not_applicable` を記録する。比較に契約が必要だが未取得の場合は `contract_ref=null`、`missing_evidence`、`assessment=indeterminate` を記録し、両者を同じ状態として扱わない。

不完全な tool または effect trace に基づく assessment は、対応する `behavior_action_observation_ref` を scope にする。execution 全体の action coverage は `behavior_action_coverage` で別に示し、未観測範囲が評価を変え得る場合は execution scope の assessment を `indeterminate` とする。`parent_lifecycle.task_complete` は lifecycle terminal の観測であり、成果契約の成功を単独で示さない。

`executions[].terminal_state` は child の `task_complete` を含む lifecycle terminal observation である。`outcome` と成果への適合は別フィールドおよび別 assessment であり、product contract の追加根拠がない限り `task_complete` 単独から成功を導かない。

`resource_usage` はexecutionの設定、行動、成果から独立したobservationである。runtimeが報告するtoken区分はmetric名と値を保持し、入力、出力、cache、reasoning、totalなど未報告の区分を補わない。経過時間は資源計測範囲が定めた開始と終了または停止のevent refsを入力にした `derived` とし、計測範囲と端点を追跡できるようにする。指定または観測できない端点は補わず、該当する経過時間を `unverified` とする。event数はcoverageが全件性を支える範囲だけを総数とし、それ以外は観測数として記録する。

providerが報告した課金額は対応する課金記録を根拠に `observed` とする。token使用量から計算した費用は `derived` とし、使用したmeasurement、各usage metricの総量・内数・独立量の関係、課金区分へのmapping、計算式、`pricing_ref`を持つ。価格基準はprovider、modelまたは課金区分、通貨、単価、適用時点、source refを保持する。対応するruntime使用量、区分間の関係、課金記録、mapping、または価格基準がない指標は `value=null`、`claim_kind=unverified` とする。

`child_handoffs` は child execution ごとの handoff を記録する。`handoff_coverage.value` は [handoff coverage](codex-runtime-evidence.md#handoff-coverage) の source 完全性評価を表す。`complete` は範囲内の各 started execution へ handoff event または不在を対応付けられる場合だけ、`partial` は既知の record または execution 対応の欠落がある場合、`unverified` は完全または部分を判定する source 保証がない場合に使う。`complete` で空配列なら範囲内に handoff はなく、`partial` または `unverified` で空配列の場合は不存在を断定しない。親の受領または利用は handoff の根拠であり、child 成果の適合を示さない。

設定と権限の assessment は `dimension` と `setting` ごとに保持する。model の `conforms` と sandbox の `mismatch` を execution 全体の単一 configuration assessment に集約しない。`summary` は mismatch と violation を列挙できるが、execution 全体の合否を導かない。

### assessment

| 値 | 意味 |
| --- | --- |
| `conforms` | 対象時点と適用範囲の契約へ適合する直接観測または導出がある。 |
| `violates` | 対象時点と適用範囲の契約に反する直接観測または導出がある。 |
| `mismatch` | definition、runtime effective configuration、actual action など、比較した対象間に差がある。契約違反は別に評価する。 |
| `indeterminate` | 比較に必要な契約、範囲、時点、記録のいずれかを確定できない。 |
| `in_progress` | cutoff 時点で child または parent が running であり、終了の評価を確定できない。 |
| `not_applicable` | その execution または分析水準に照合対象がない。 |

`mismatch` を `violates`、`in_progress` を失敗、`current_only` を historical `exact` と読み替えない。child terminal state と parent completion relation は別のフィールドで報告する。
