import json
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bundle/skills/agent-harness/agent-benchmarking/scripts/benchmark.py"
FIXTURES = Path(__file__).parent / "fixtures"
SHA = "a" * 64
OTHER_SHA = "b" * 64
SOURCE_DIGEST = hashlib.sha256(b'{"type":"turn"}\n').hexdigest()


def call(*arguments, check=True):
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, arguments)], text=True, capture_output=True, check=check)


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def save(path, value):
    Path(path).write_text(json.dumps(value), encoding="utf-8")


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.outside = tempfile.TemporaryDirectory()
        self.work = Path(self.temporary.name) / "synthetic-suite" / "1.0.0"
        self.work.mkdir(parents=True)
        shutil.copytree(FIXTURES / "cases", self.work / "cases")
        shutil.copyfile(FIXTURES / "suite.json", self.work / "suite.json")
        for relative, content in load(FIXTURES / "source-files.json").items():
            target = self.work / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        self.suite = self.work / "suite.json"

    def tearDown(self):
        self.temporary.cleanup()
        self.outside.cleanup()

    def definition(self, purpose="change-regression", use_kind="formal-comparison"):
        cases = [{"case_key": f"case-{number:02d}", "independence_group": f"group-{number:02d}"} for number in range(1, 11)]
        configurations = [
            {"variant_id": "reference", "component_digests": [SHA], "model": "model", "reasoning_effort": "low", "effective_configuration": {"temperature": 0}},
            {"variant_id": "candidate", "component_digests": [OTHER_SHA], "model": "model", "reasoning_effort": "low", "effective_configuration": {"temperature": 0}},
        ]
        if purpose == "model-effort-comparison":
            configurations = [
                {"variant_id": "reference", "component_digests": [SHA], "model": "model-a", "reasoning_effort": "high", "effective_configuration": {"temperature": 0}},
                {"variant_id": "candidate", "component_digests": [SHA], "model": "model-a", "reasoning_effort": "max", "effective_configuration": {"temperature": 0}},
                {"variant_id": "model-b-high", "component_digests": [SHA], "model": "model-b", "reasoning_effort": "high", "effective_configuration": {"temperature": 0}},
                {"variant_id": "model-b-max", "component_digests": [SHA], "model": "model-b", "reasoning_effort": "max", "effective_configuration": {"temperature": 0}},
            ]
        units = {
            "quality": "score",
            "reliability": "score",
            "safety": "score",
            "time": "seconds",
            "token": "tokens",
            "provider-reported-cost": "USD",
            "derived-cost": "USD",
        }
        plan = {axis: {"metric_id": "quality" if axis == "quality" else axis, "unit": units[axis], "aggregation": "mean"} for axis in units}
        plan["provider-reported-cost"]["pareto_selected"] = True
        definition = {
            "definition_id": "frozen-definition",
            "selection_locked": True,
            "use_kind": use_kind,
            "experiment_purpose": purpose,
            "suite": {"id": "suite", "version": "1.0.0", "repository": "owner/repo", "git_sha": "c" * 40, "digest": SHA},
            "hypothesis": "candidate is better by the predefined amount",
            "primary_metric": {"metric_id": "quality", "favorable_direction": "higher", "practical_minimum_difference": 0.1},
            "cases": cases,
            "configurations": configurations,
            "reference_variant_id": "reference",
            "fixed_factors": {"suite": SHA},
            "measurement_plan": plan,
            "pairing_rule": {"case_outer": True},
            "aggregation_rule": {"replicates": "mean", "unit": "case-paired"},
            "exclusion_rule": {"rule": "none"},
            "missingness_rule": {"rule": "report"},
            "replicate_count": 1 if use_kind == "completeness-pilot" else 3,
            "seed": 7,
            "execution_order": "fixed",
            "budget": {"tokens": 100},
            "stop_conditions": {"deadline": "fixed"},
            "grader": self.grade(),
            "hard_gates": {"safety": {"rule": "must pass"}},
            "candidate_boundary": {"identity": "candidate", "access": "workspace only", "evidence": "boundary-evidence"},
            "controller_boundary": {"identity": "controller", "access": "controller only", "evidence": "boundary-evidence"},
            "oracle_boundary": {"identity": "oracle", "access": "oracle only", "evidence": "boundary-evidence"},
            "required_evidence": ["raw-jsonl"],
            "evidence_producers": {
                "execution": {"kind": "delegated-execution", "identity": "controller", "version_or_digest": SHA},
                "grade": {"kind": "existing-raw-evidence", "identity": "grader", "version_or_digest": "grader-v1"},
            },
        }
        artifact = self.outside_path(f"suite-validation-{len(list(Path(self.outside.name).glob('suite-validation-*')))}.json")
        artifact_cases = [
            {"case_key": case["case_key"], "split": "validation", "task_family": "test", "group": case["independence_group"]}
            for case in cases
        ]
        artifact_value = {"suite_id": "suite", "suite_version": "1.0.0", "suite_digest": SHA, "git_sha": "c" * 40, "cases": artifact_cases}
        save(artifact, artifact_value)
        definition["suite"]["validation_artifact_path"] = str(artifact)
        definition["suite"]["validation_artifact_digest"] = hashlib.sha256(artifact.read_bytes()).hexdigest()
        return definition

    def outside_path(self, name):
        return Path(self.outside.name) / name

    def grade(self, kind="human", calibration="calibrated"):
        return {"kind": kind, "version_or_digest": "grader-v1", "rubric_ref": "rubric-ref", "gold_ref": "gold-ref", "blind_state": "blind", "calibration": calibration, "adjudication": "none", "producer": "grader", "evidence_refs": ["grade-evidence"]}

    def create_record(self, definition=None):
        index = len(list(self.work.glob("record-*")))
        definition_path = self.work / f"definition-{index}.json"
        output = self.work / f"record-{index}"
        save(definition_path, definition or self.definition())
        call("init", "--definition", definition_path, "--output", output)
        return output / "benchmark_record.json"

    def import_evidence(self, record):
        source = self.work / f"events-{len(list(self.work.glob('events-*')))}.jsonl"
        source.write_text('{"type":"turn"}\n', encoding="utf-8")
        call("import-codex", "--record", record, "--jsonl", source)

    def refresh_run_evidence(self, run):
        projection = {key: value for key, value in run.items() if key not in {"execution_evidence_path", "execution_evidence_digest"}}
        evidence = {
            "schema_version": 1,
            "producer": {"kind": "delegated-execution", "identity": "controller", "version_or_digest": SHA},
            "subject_id": run["run_id"],
            "claim_digest": hashlib.sha256((json.dumps(projection, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest(),
            "source_refs": [{"source_digest": run["source_digest"], "event_locator": run["event_locator"]}],
            "access_audit": {
                "suite_access": run["suite_access"],
                "controller_access": run["controller_access"],
                "oracle_access": run["oracle_access"],
                "gold_access": run["gold_access"],
                "evidence_refs": [run["candidate_access_audit_evidence"]],
            },
        }
        path = Path(run.get("execution_evidence_path") or (Path(self.outside.name) / f"run-evidence-{run['run_id']}.json"))
        save(path, evidence)
        run["execution_evidence_path"] = str(path)
        run["execution_evidence_digest"] = hashlib.sha256(path.read_bytes()).hexdigest()

    def refresh_grade_evidence(self, grade):
        projection = {key: value for key, value in grade.items() if key not in {"grade_evidence_path", "grade_evidence_digest"}}
        evidence = {
            "schema_version": 1,
            "producer": {"kind": "existing-raw-evidence", "identity": grade["producer"], "version_or_digest": grade["version_or_digest"]},
            "subject_id": grade["grade_id"],
            "claim_digest": hashlib.sha256((json.dumps(projection, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest(),
            "evidence_refs": grade["evidence_refs"],
        }
        path = Path(grade.get("grade_evidence_path") or (Path(self.outside.name) / f"grade-evidence-{grade['grade_id']}.json"))
        save(path, evidence)
        grade["grade_evidence_path"] = str(path)
        grade["grade_evidence_digest"] = hashlib.sha256(path.read_bytes()).hexdigest()

    def make_run_and_grade(
        self,
        definition,
        case,
        variant,
        replicate,
        quality=1.0,
        gate=True,
        include_grade_measurements=True,
        elapsed=2.0,
        provider_cost=0.2,
        derived_cost=0.3,
    ):
        configuration = next(item for item in definition["configurations"] if item["variant_id"] == variant)
        run_id = f"run-{case}-{variant}-{replicate}"
        grade_id = f"grade-{case}-{variant}-{replicate}"
        input_files = [{"path": "candidate/request.md", "digest": SHA}]
        input_digest = hashlib.sha256((json.dumps(input_files, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()
        run = {
            "run_id": run_id,
            "attempt_id": f"attempt-{case}-{variant}-{replicate}",
            "attempt_index": 1,
            "grade_id": grade_id,
            "case_key": case,
            "variant_id": variant,
            "replicate_index": replicate,
            "model": configuration["model"],
            "reasoning_effort": configuration["reasoning_effort"],
            "component_digests": configuration["component_digests"],
            "effective_configuration": configuration["effective_configuration"],
            "fixed_factors": definition["fixed_factors"],
            "input_digest": input_digest,
            "source_digest": SOURCE_DIGEST,
            "event_locator": {"line": 1, "byte_offset": 0, "digest": hashlib.sha256(b'{"type":"turn"}').hexdigest(), "type": "turn"},
            "coverage": {"status": "complete", "event_count": 1, "event_types": {"turn": 1}, "missing_scopes": []},
            "suite_digest": SHA,
            "git_sha": "c" * 40,
            "materialization_manifest_digest": SHA,
            "candidate_access_audit_evidence": "access-audit",
            "suite_access": False,
            "controller_access": False,
            "gold_access": False,
            "oracle_access": False,
            "posthoc_case_selection": False,
            "fixed_factor_mapping_valid": True,
            "status": "completed",
            "metric_id": "quality",
            "time": elapsed,
            "token": 10,
            "provider_cost": provider_cost,
            "provider_cost_evidence": "billing-event",
            "derived_cost": derived_cost,
            "price_source": "price-sheet",
            "price_version_or_digest": SHA,
            "effective_timestamp": "2026-01-01T00:00:00Z",
            "currency": "USD",
            "billing_unit": "token",
            "usage_mapping": "reported token",
            "formula": "tokens * price",
            "input_refs": "usage-event",
            "calculation_timestamp": "2026-01-01T00:00:00Z",
        }
        manifest = {"case_key": case, "suite_digest": SHA, "git_sha": "c" * 40, "input_digest": input_digest, "files": input_files}
        manifest_path = Path(self.outside.name) / f"manifest-{case}-{variant}-{replicate}.json"
        save(manifest_path, manifest)
        run["materialization_manifest_path"] = str(manifest_path)
        run["materialization_manifest_digest"] = hashlib.sha256((json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()
        run["measurements"] = [
                {"metric_id": "time", "value": elapsed},
                {"metric_id": "token", "value": 10.0},
                {"metric_id": "provider-reported-cost", "value": provider_cost},
                {"metric_id": "derived-cost", "value": derived_cost},
            ]
        self.refresh_run_evidence(run)
        grade = self.grade()
        grade.update({
            "grade_id": grade_id,
            "run_id": run_id,
            "status": "completed",
            "grader_failure": None,
            "candidate_failure": None,
            "primary_metric_value": quality if include_grade_measurements else None,
            "dimension_measurements": [
                {"metric_id": "reliability", "value": 1.0},
                {"metric_id": "safety", "value": 1.0},
            ] if include_grade_measurements else [
                {"metric_id": "safety", "value": 1.0},
            ],
            "hard_gate_results": {"safety": {"passed": gate, "evidence": "gate-evidence"}},
        })
        self.refresh_grade_evidence(grade)
        return run, grade

    def append_run(self, record, definition, case, variant, replicate, **kwargs):
        run, grade = self.make_run_and_grade(definition, case, variant, replicate, **kwargs)
        record["runs"].append(run)
        record["grades"].append(grade)
        return run, grade

    def ready_formal_record(self, purpose="change-regression", candidate_quality=2.0, gate=True):
        definition = self.definition(purpose=purpose)
        record = self.create_record(definition)
        value = load(record)
        model_values = {
            "reference": (1.0, 2.0, 0.20),
            "candidate": (candidate_quality, 2.5, 0.24),
            "model-b-high": (1.4, 1.8, 0.16),
            "model-b-max": (1.8, 3.0, 0.28),
        }
        for case in definition["cases"]:
            for configuration in definition["configurations"]:
                variant = configuration["variant_id"]
                quality, elapsed, cost = model_values.get(variant, (candidate_quality, 2.0, 0.2))
                for replicate in range(1, 4):
                    self.append_run(
                        value,
                        definition,
                        case["case_key"],
                        variant,
                        replicate,
                        quality=quality,
                        gate=gate,
                        elapsed=elapsed,
                        provider_cost=cost,
                        derived_cost=cost * 1.1,
                    )
        save(record, value)
        self.import_evidence(record)
        call("validate", "--record", record)
        self.assertEqual(load(record)["state"], "comparison-ready")
        return record, definition

    def test_suite_rejects_unknown_split_collision_symlink_traversal_and_digest_change(self):
        valid = self.outside_path("valid.json")
        call("validate-suite", "--suite", self.suite, "--output", valid)
        changed = self.work / "changed.json"
        request = self.work / "cases/case-01/candidate/request.md"
        original_request = request.read_text(encoding="utf-8")
        request.write_text("changed", encoding="utf-8")
        self.assertEqual(call("validate-suite", "--suite", self.suite, "--output", changed, check=False).returncode, 2)
        self.assertEqual(call("materialize-case", "--suite", self.suite, "--case-key", "case-01", "--output", Path(self.outside.name) / "changed", "--manifest-output", Path(self.outside.name) / "changed-manifest.json", check=False).returncode, 2)
        request.write_text(original_request, encoding="utf-8")
        (self.work / "cases/case-01/unknown.txt").write_text("x", encoding="utf-8")
        self.assertEqual(call("validate-suite", "--suite", self.suite, "--output", self.work / "bad.json", check=False).returncode, 2)
        (self.work / "cases/case-01/unknown.txt").unlink()
        link = self.work / "cases/case-01/candidate/inputs/link.json"
        link.symlink_to(self.work / "suite.json")
        self.assertEqual(call("validate-suite", "--suite", self.suite, "--output", self.work / "bad2.json", check=False).returncode, 2)
        link.unlink()
        suite = load(self.suite)
        suite["cases"][0]["split"] = "invalid-split"
        save(self.suite, suite)
        self.assertEqual(call("validate-suite", "--suite", self.suite, "--output", self.work / "bad-split.json", check=False).returncode, 2)
        suite["cases"][0]["split"] = "validation"
        save(self.suite, suite)
        (self.work / "cases/case-01/unexpected-directory").mkdir()
        self.assertEqual(call("validate-suite", "--suite", self.suite, "--output", self.work / "bad-directory.json", check=False).returncode, 2)
        (self.work / "cases/case-01/unexpected-directory").rmdir()

    def test_materialization_is_fresh_isolated_and_manifest_is_external(self):
        workspace = Path(self.outside.name) / "candidate"
        manifest = Path(self.outside.name) / "manifest.json"
        call("materialize-case", "--suite", self.suite, "--case-key", "case-01", "--output", workspace, "--manifest-output", manifest)
        self.assertTrue((workspace / "candidate/request.md").is_file())
        self.assertFalse((workspace / "controller").exists())
        self.assertFalse((workspace / "oracle").exists())
        self.assertEqual(call("materialize-case", "--suite", self.suite, "--case-key", "case-01", "--output", workspace, "--manifest-output", Path(self.outside.name) / "second.json", check=False).returncode, 2)
        self.assertEqual(call("materialize-case", "--suite", self.suite, "--case-key", "case-01", "--output", Path(self.outside.name) / "candidate2", "--manifest-output", Path(self.outside.name) / "candidate2/manifest.json", check=False).returncode, 2)

    def test_definition_requires_locked_types_boundaries_and_llm_calibration(self):
        definition = self.definition()
        definition["selection_locked"] = False
        self.assertEqual(call("init", "--definition", self.write_definition(definition), "--output", self.work / "bad", check=False).returncode, 2)
        definition = self.definition()
        definition["suite"]["digest"] = "not-a-digest"
        definition["candidate_boundary"] = {"identity": "candidate"}
        self.assertEqual(call("init", "--definition", self.write_definition(definition), "--output", self.work / "bad2", check=False).returncode, 2)
        definition = self.definition()
        definition["grader"]["kind"] = "llm-judge"
        definition["grader"]["calibration"] = ""
        self.assertEqual(call("init", "--definition", self.write_definition(definition), "--output", self.work / "bad3", check=False).returncode, 2)
        definition = self.definition()
        definition["grader"]["kind"] = "llm-judge"
        definition["grader"]["calibration"] = "unverified"
        definition["cases"][1]["independence_group"] = definition["cases"][0]["independence_group"]
        definition["replicate_count"] = False
        self.assertEqual(call("init", "--definition", self.write_definition(definition), "--output", self.work / "bad4", check=False).returncode, 2)
        definition = self.definition()
        definition["cases"][0]["oracle"] = "secret"
        self.assertEqual(call("init", "--definition", self.write_definition(definition), "--output", self.work / "bad5", check=False).returncode, 2)
        definition = self.definition()
        definition["replicate_count"] = 2
        definition["hard_gates"] = {"safety": "must pass"}
        self.assertEqual(call("init", "--definition", self.write_definition(definition), "--output", self.work / "bad6", check=False).returncode, 2)

    def write_definition(self, definition):
        path = self.work / f"input-{len(list(self.work.glob('input-*')))}.json"
        save(path, definition)
        return path

    def test_formal_requires_exact_runs_and_fixed_configuration(self):
        record = self.create_record()
        value = load(record)
        definition = value["benchmark_definition"]
        run, grade = self.make_run_and_grade(definition, "case-01", "reference", 1)
        run["model"] = "changed"
        self.refresh_run_evidence(run)
        value["runs"] = [run]
        value["grades"] = [grade]
        save(record, value)
        self.import_evidence(record)
        failed = call("validate", "--record", record, check=False)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(load(record)["state"], "invalid")
        tampered_record = self.create_record()
        tampered_value = load(tampered_record)
        run, grade = self.make_run_and_grade(tampered_value["benchmark_definition"], "case-01", "reference", 1)
        run["token"] = 999
        tampered_value["runs"] = [run]
        tampered_value["grades"] = [grade]
        save(tampered_record, tampered_value)
        self.import_evidence(tampered_record)
        self.assertEqual(call("validate", "--record", tampered_record, check=False).returncode, 2)
        self.assertEqual(load(tampered_record)["state"], "invalid")
        definition = self.definition()
        definition["configurations"][1]["model"] = "other"
        self.assertEqual(call("init", "--definition", self.write_definition(definition), "--output", self.work / "bad-fixed", check=False).returncode, 2)

    def test_grade_cost_pilot_and_single_observation_states_are_separate(self):
        pilot = self.definition(use_kind="completeness-pilot")
        record = self.create_record(pilot)
        value = load(record)
        value["runs"] = []
        value["grades"] = []
        for case in pilot["cases"]:
            for configuration in pilot["configurations"]:
                self.append_run(
                    value,
                    pilot,
                    case["case_key"],
                    configuration["variant_id"],
                    1,
                    include_grade_measurements=False,
                )
        save(record, value)
        self.import_evidence(record)
        call("validate", "--record", record)
        self.assertEqual(load(record)["state"], "pilot-complete")
        value = load(record)
        value["runs"][0]["private_prompt"] = "forbidden"
        save(record, value)
        self.assertEqual(call("validate", "--record", record, check=False).returncode, 2)
        self.assertEqual(load(record)["state"], "invalid")
        record = self.create_record(pilot)
        value = load(record)
        for case in pilot["cases"]:
            for configuration in pilot["configurations"]:
                self.append_run(value, pilot, case["case_key"], configuration["variant_id"], 1, include_grade_measurements=False)
        value["grades"][0].update({"status": "grader-failure", "grader_failure": "grader unavailable", "hard_gate_results": {}})
        self.refresh_grade_evidence(value["grades"][0])
        save(record, value)
        self.import_evidence(record)
        call("validate", "--record", record)
        self.assertEqual(load(record)["state"], "incomplete")
        record = self.create_record(pilot)
        value = load(record)
        run, grade = self.make_run_and_grade(
            pilot,
            "case-01",
            "reference",
            1,
            include_grade_measurements=False,
        )
        grade["evidence_refs"] = ""
        self.refresh_grade_evidence(grade)
        value["runs"] = [run]
        value["grades"] = [grade]
        save(record, value)
        self.import_evidence(record)
        call("validate", "--record", record)
        self.assertEqual(load(record)["state"], "incomplete")
        value = load(record)
        value["runs"][0]["derived_cost"] = 1
        value["runs"][0].pop("price_source")
        self.refresh_run_evidence(value["runs"][0])
        save(record, value)
        call("validate", "--record", record)
        self.assertEqual(load(record)["state"], "incomplete")
        formal = self.create_record()
        value = load(formal)
        run, grade = self.make_run_and_grade(value["benchmark_definition"], "case-01", "reference", 1)
        value["runs"] = [run]
        value["grades"] = [grade]
        save(formal, value)
        self.import_evidence(formal)
        call("validate", "--record", formal)
        self.assertEqual(load(formal)["state"], "incomplete")

    def test_jsonl_import_is_locator_based_idempotent_and_digest_is_stable(self):
        record = self.create_record()
        self.import_evidence(record)
        first = load(record)
        self.import_evidence(record)
        second = load(record)
        self.assertEqual(len(second["imports"]), 1)
        self.assertEqual(first["record_digest"], second["record_digest"])
        imported = second["imports"][0]
        self.assertTrue(os.path.isabs(imported["absolute_path"]))
        self.assertIn("event_locators", imported)
        self.assertNotIn('{"type":"turn"}', json.dumps(second))

    def test_bootstrap_pmd_lower_gate_and_secondary_axes(self):
        record, definition = self.ready_formal_record(candidate_quality=1.1)
        record_value = load(record)
        failed_run = next(run for run in record_value["runs"] if run["variant_id"] == "candidate")
        failed_grade = next(grade for grade in record_value["grades"] if grade["grade_id"] == failed_run["grade_id"])
        failed_grade.update({"status": "candidate-failure", "candidate_failure": "contract failure"})
        self.refresh_grade_evidence(failed_grade)
        save(record, record_value)
        call("validate", "--record", record)
        self.assertEqual(load(record)["state"], "comparison-ready")
        comparison = self.work / "comparison.json"
        call("compare", "--record", record, "--reference-variant", "reference", "--candidate-variant", "candidate", "--output", comparison)
        result = load(comparison)
        self.assertEqual(result["conclusion"], "supported")
        self.assertEqual(result["resamples"], 10_000)
        self.assertEqual(result["bootstrap"], {"method": "paired-bootstrap", "unit": "case", "replicate_aggregation": "mean"})
        self.assertEqual(result["eligibility"]["status"], "eligible")
        self.assertTrue(result["hard_gate_results"]["safety"]["passed"])
        self.assertEqual(result["grade_status_counts"]["candidate"]["candidate-failure"], 1)
        self.assertEqual({axis["axis"] for axis in result["axes"]}, {"quality", "reliability", "safety", "time", "token", "provider-reported-cost", "derived-cost"})
        record, definition = self.ready_formal_record(candidate_quality=0.0)
        comparison = self.work / "comparison-low.json"
        call("compare", "--record", record, "--reference-variant", "reference", "--candidate-variant", "candidate", "--output", comparison)
        self.assertEqual(load(comparison)["conclusion"], "not-supported")
        lower_record, lower_definition = self.ready_formal_record(candidate_quality=0.8)
        lower_definition["primary_metric"]["favorable_direction"] = "lower"
        save(lower_record, {**load(lower_record), "benchmark_definition": lower_definition})
        call("validate", "--record", lower_record)
        lower_comparison = self.work / "comparison-lower.json"
        call("compare", "--record", lower_record, "--reference-variant", "reference", "--candidate-variant", "candidate", "--output", lower_comparison)
        lower_result = load(lower_comparison)
        self.assertEqual(lower_result["conclusion"], "supported")
        primary_pair = next(axis for axis in lower_result["axes"] if axis["axis"] == "quality")["case_values"][0]
        self.assertAlmostEqual(primary_pair["raw_delta"], -0.2)
        self.assertAlmostEqual(primary_pair["oriented_delta"], 0.2)
        record, definition = self.ready_formal_record(candidate_quality=2.0, gate=False)
        comparison = self.work / "comparison-gate.json"
        call("compare", "--record", record, "--reference-variant", "reference", "--candidate-variant", "candidate", "--output", comparison)
        self.assertEqual(load(comparison)["conclusion"], "not-supported")

    @unittest.skipUnless(os.environ.get("BENCHMARK_REPORT_ENVIRONMENT"), "requires the pinned artifact-local report environment")
    def test_reports_are_private_safe_self_contained_and_have_required_charts(self):
        record, definition = self.ready_formal_record()
        record_value = load(record)
        record_value["runs"][0]["candidate_access_audit_evidence"] = "/private/secret"
        self.refresh_run_evidence(record_value["runs"][0])
        save(record, record_value)
        call("validate", "--record", record)
        comparison = self.work / "comparison.json"
        call("compare", "--record", record, "--reference-variant", "reference", "--candidate-variant", "candidate", "--output", comparison)
        output = Path(self.outside.name) / "change-report"
        call("report", "--record", record, "--comparison", comparison, "--output", output)
        required = {"report.html", "report.md", "metrics.csv", "comparison.json", "report_manifest.json", "thread-summary.md", "charts/paired-delta.svg", "charts/paired-delta.png", "charts/reliability.svg", "charts/reliability.png"}
        actual = {path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()}
        self.assertEqual(actual, required)
        reliability_chart = (output / "charts/reliability.svg").read_text()
        self.assertIn("reliability-case-deltas", reliability_chart)
        self.assertIn("reliability-confidence-band", reliability_chart)
        self.assertIn("reliability-estimate", reliability_chart)
        html_report = (output / "report.html").read_text()
        report = html_report + (output / "report.md").read_text()
        self.assertNotIn("case-01", report)
        self.assertNotIn("gold-ref", report)
        self.assertIn("Formal paired", report)
        self.assertIn("Hypothesis:", report)
        self.assertIn("<svg", html_report)
        self.assertNotIn("<?xml", html_report)
        self.assertNotIn("<!DOCTYPE svg", html_report)
        manifest = load(output / "report_manifest.json")
        self.assertIn("report_manifest.json", manifest["artifacts"])
        self.assertEqual(manifest["backend"].lower(), "agg")
        self.assertTrue(manifest["render_config"]["self_contained_html"])
        self.assertIn("matplotlib==3.11.1", [package.lower() for package in manifest["packages"]])
        self.assertIn("numpy==2.5.2", [package.lower() for package in manifest["packages"]])
        public_comparison = load(output / "comparison.json")
        self.assertEqual(public_comparison["definition_id"], definition["definition_id"])
        self.assertEqual(public_comparison["evidence_coverage"]["run_evidence_verified"], 60)
        self.assertEqual(len(public_comparison["case_coverage"]), 20)
        self.assertTrue(public_comparison["re_evaluation_triggers"])
        private_markers = (b'"case-01"', b"gold-ref", b"/private/secret")
        self.assertFalse(any(marker in path.read_bytes() for path in output.rglob("*") if path.is_file() for marker in private_markers))
        tampered = self.work / "tampered-comparison.json"
        tampered_value = load(comparison)
        tampered_value["conclusion"] = "inconclusive"
        save(tampered, tampered_value)
        self.assertEqual(call("report", "--record", record, "--comparison", tampered, "--output", Path(self.outside.name) / "tampered-report", check=False).returncode, 2)
        model_record, _ = self.ready_formal_record(purpose="model-effort-comparison")
        model_comparison = self.work / "model-comparison.json"
        call("compare", "--record", model_record, "--reference-variant", "reference", "--candidate-variant", "candidate", "--output", model_comparison)
        model_output = Path(self.outside.name) / "model-report"
        call("report", "--record", model_record, "--comparison", model_comparison, "--output", model_output)
        model_expected = {
            "report.html", "report.md", "metrics.csv", "comparison.json", "report_manifest.json", "thread-summary.md",
            "charts/metric-heatmap.svg", "charts/metric-heatmap.png",
            "charts/quality-cost-pareto.svg", "charts/quality-cost-pareto.png",
            "charts/quality-time-pareto.svg", "charts/quality-time-pareto.png",
            "charts/reliability.svg", "charts/reliability.png",
        }
        self.assertEqual({path.relative_to(model_output).as_posix() for path in model_output.rglob("*") if path.is_file()}, model_expected)
        heatmap = (model_output / "charts/metric-heatmap.svg").read_text()
        cost_pareto = (model_output / "charts/quality-cost-pareto.svg").read_text()
        time_pareto = (model_output / "charts/quality-time-pareto.svg").read_text()
        for variant, value in (("reference", "1.000"), ("candidate", "2.000"), ("model-b-high", "1.400"), ("model-b-max", "1.800")):
            self.assertIn(f"heatmap-value-{variant}", heatmap)
            self.assertIn(value, heatmap)
            self.assertIn(variant, cost_pareto)
            self.assertIn(variant, time_pareto)
        self.assertIn("pareto-frontier", cost_pareto)
        self.assertIn("pareto-frontier", time_pareto)
        pilot_definition = self.definition(purpose="model-effort-comparison", use_kind="completeness-pilot")
        pilot_record = self.create_record(pilot_definition)
        pilot_value = load(pilot_record)
        for case in pilot_definition["cases"]:
            for configuration in pilot_definition["configurations"]:
                derived_cost = {
                    "reference": 0.7,
                    "candidate": 0.4,
                    "model-b-high": 0.25,
                    "model-b-max": 0.17,
                }[configuration["variant_id"]]
                self.append_run(
                    pilot_value,
                    pilot_definition,
                    case["case_key"],
                    configuration["variant_id"],
                    1,
                    include_grade_measurements=False,
                    derived_cost=derived_cost,
                )
        pilot_value["runs"][0]["effective_timestamp"] = "/private/secret-date"
        self.refresh_run_evidence(pilot_value["runs"][0])
        pilot_value["grades"][0].update({
            "status": "candidate-failure",
            "candidate_failure": "contract failure",
            "hard_gate_results": {"safety": {"passed": False, "evidence": "gate-evidence"}},
        })
        self.refresh_grade_evidence(pilot_value["grades"][0])
        save(pilot_record, pilot_value)
        self.import_evidence(pilot_record)
        call("validate", "--record", pilot_record)
        pilot_output = Path(self.outside.name) / "pilot-report"
        call("report", "--record", pilot_record, "--output", pilot_output)
        pilot_expected = {
            "report.html", "report.md", "metrics.csv", "comparison.json", "report_manifest.json", "thread-summary.md",
            "charts/pilot-grade-status.svg", "charts/pilot-grade-status.png",
            "charts/pilot-hard-gates.svg", "charts/pilot-hard-gates.png",
            "charts/pilot-elapsed-time.svg", "charts/pilot-elapsed-time.png",
            "charts/pilot-public-price-cost.svg", "charts/pilot-public-price-cost.png",
            "charts/pilot-performance-cost-curve.svg", "charts/pilot-performance-cost-curve.png",
        }
        self.assertEqual({path.relative_to(pilot_output).as_posix() for path in pilot_output.rglob("*") if path.is_file()}, pilot_expected)
        self.assertIsNone(load(pilot_output / "comparison.json")["conclusion"])
        self.assertEqual(load(pilot_output / "report_manifest.json")["report_status"], "pilot-complete")
        pilot_manifest = load(pilot_output / "report_manifest.json")
        self.assertEqual(pilot_manifest["price_basis"]["catalog_digests"], [SHA])
        self.assertIn("not provider-billed", pilot_manifest["price_basis"]["interpretation"])
        pilot_svgs = {
            path.name: path.read_text(encoding="utf-8")
            for path in (pilot_output / "charts").glob("*.svg")
        }
        self.assertIn("pilot-grade-status", pilot_svgs["pilot-grade-status.svg"])
        self.assertIn("pilot-hard-gates", pilot_svgs["pilot-hard-gates.svg"])
        self.assertIn("pilot-elapsed-time", pilot_svgs["pilot-elapsed-time.svg"])
        self.assertIn("pilot-public-price-cost", pilot_svgs["pilot-public-price-cost.svg"])
        performance_cost = pilot_svgs["pilot-performance-cost-curve.svg"]
        self.assertIn("Pilot cost–coverage curves by model and reasoning effort", performance_cost)
        self.assertIn("Accepted case coverage within threshold", performance_cost)
        self.assertIn("public API price estimate threshold per Run (USD, log scale)", performance_cost)
        for configuration in ("model-a / high", "model-a / max", "model-b / high", "model-b / max"):
            self.assertIn(configuration, performance_cost)
        self.assertIn("filled marker = Accepted · hollow marker = not Accepted", performance_cost)
        self.assertIn("public API price estimate", pilot_svgs["pilot-public-price-cost.svg"])
        self.assertIn("public pricing observed 2026-01-01", pilot_svgs["pilot-public-price-cost.svg"])
        self.assertIn("pilot-elapsed-time-case-001-reference-bar", pilot_svgs["pilot-elapsed-time.svg"])
        self.assertIn("pilot-public-price-cost-case-001-reference-bar", pilot_svgs["pilot-public-price-cost.svg"])
        self.assertNotIn("pilot-end-to-end-tokens", "".join(pilot_svgs))
        self.assertNotIn("/private/secret-date", "".join(path.read_text(errors="ignore") for path in pilot_output.rglob("*") if path.is_file()))
        self.assertIn("candidate-failure", pilot_svgs["pilot-grade-status.svg"].lower())
        self.assertIn("1/1", pilot_svgs["pilot-hard-gates.svg"])
        for source in pilot_svgs.values():
            self.assertIn("n=1 per case", source)
            self.assertIn("descriptive only", source)
            self.assertNotIn("confidence interval", source.lower())
            self.assertNotIn("pareto-frontier", source)
            self.assertNotIn("supported", source.lower())
            self.assertNotIn("inconclusive", source.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
