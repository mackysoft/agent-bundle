#!/usr/bin/env python3
"""Fail-closed, file-oriented helpers for the Agent Benchmarking Skill.

This module deliberately does not execute candidates or graders.  It validates
the frozen inputs and turns already-produced evidence into bounded artifacts.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import os
import random
import re
import shutil
import subprocess
import sys
import venv
from collections import Counter
from datetime import date
from pathlib import Path
from statistics import fmean
from typing import Any


SCHEMA_VERSION = 1
SUITE_SCHEMA_VERSION = "1.0"
CASE_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
BOOTSTRAP_RESAMPLES = 10_000
ROOT = Path(__file__).parent
SPLITS = {"pilot", "development", "validation", "sealed"}
USE_KINDS = {"completeness-pilot", "formal-comparison"}
PURPOSES = {"change-regression", "model-effort-comparison"}
MEASUREMENT_AXES = {
    "quality",
    "reliability",
    "safety",
    "time",
    "token",
    "provider-reported-cost",
    "derived-cost",
}
GRADE_PROVENANCE = (
    "kind",
    "version_or_digest",
    "rubric_ref",
    "gold_ref",
    "blind_state",
    "calibration",
    "adjudication",
    "producer",
    "evidence_refs",
)
RUN_FIELDS = {
    "run_id", "attempt_id", "attempt_index", "grade_id", "case_key", "variant_id",
    "replicate_index", "model", "reasoning_effort", "component_digests",
    "effective_configuration", "fixed_factors", "input_digest", "source_digest",
    "event_locator", "coverage", "suite_digest", "git_sha",
    "materialization_manifest_path", "materialization_manifest_digest",
    "candidate_access_audit_evidence", "status", "metric_id", "time", "token",
    "provider_cost", "provider_cost_evidence", "derived_cost", "price_source",
    "price_version_or_digest", "effective_timestamp", "currency", "billing_unit",
    "usage_mapping", "formula", "input_refs", "calculation_timestamp", "measurements",
    "suite_access", "controller_access", "gold_access", "oracle_access",
    "posthoc_case_selection", "fixed_factor_mapping_valid", "execution_evidence_path",
    "execution_evidence_digest",
}
GRADE_FIELDS = {
    "grade_id", "run_id", *GRADE_PROVENANCE, "primary_metric_value",
    "dimension_measurements", "hard_gate_results", "status", "grader_failure",
    "candidate_failure", "grade_evidence_path", "grade_evidence_digest",
}
RECORD_FIELDS = {
    "schema_version", "benchmark_definition", "imports", "runs", "grades", "state",
    "record_digest", "validation",
}
REQUIRED_DEFINITION = (
    "definition_id",
    "selection_locked",
    "use_kind",
    "experiment_purpose",
    "suite",
    "hypothesis",
    "primary_metric",
    "cases",
    "configurations",
    "reference_variant_id",
    "fixed_factors",
    "measurement_plan",
    "pairing_rule",
    "aggregation_rule",
    "exclusion_rule",
    "missingness_rule",
    "replicate_count",
    "seed",
    "execution_order",
    "budget",
    "stop_conditions",
    "grader",
    "hard_gates",
    "candidate_boundary",
    "controller_boundary",
    "oracle_boundary",
    "required_evidence",
    "evidence_producers",
)
SUITE_DEFINITION_FIELDS = {
    "id", "version", "repository", "git_sha", "digest",
    "validation_artifact_path", "validation_artifact_digest",
}
PRIMARY_METRIC_FIELDS = {
    "metric_id", "favorable_direction", "practical_minimum_difference",
}
CASE_DEFINITION_FIELDS = {"case_key", "independence_group"}
CONFIGURATION_FIELDS = {
    "variant_id", "component_digests", "model", "reasoning_effort",
    "effective_configuration",
}
MEASUREMENT_SPECIFICATION_FIELDS = {"metric_id", "unit", "aggregation"}
BOUNDARY_FIELDS = {"identity", "access", "evidence"}
GRADE_STATUSES = {"completed", "grader-failure", "candidate-failure"}
PRODUCER_KINDS = {
    "skill-behavior-validation",
    "custom-agent-behavior-validation",
    "delegated-execution",
    "subagent-execution-analysis",
    "existing-raw-evidence",
}
PRODUCER_FIELDS = {"kind", "identity", "version_or_digest"}
RUN_EVIDENCE_FIELDS = {
    "schema_version", "producer", "subject_id", "claim_digest", "source_refs",
    "access_audit",
}
GRADE_EVIDENCE_FIELDS = {
    "schema_version", "producer", "subject_id", "claim_digest", "evidence_refs",
}
ACCESS_AUDIT_FIELDS = {
    "suite_access", "controller_access", "oracle_access", "gold_access",
    "evidence_refs",
}


class ContractError(ValueError):
    """A supplied artifact does not meet the frozen benchmarking contract."""


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def canonical_source_json(value: Any) -> bytes:
    """The producer's suite digest deliberately has no trailing newline."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def is_sha1(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 40 and all(character in "0123456789abcdef" for character in value)


def read_json(path: Path | str) -> dict[str, Any]:
    source = Path(path)
    if source.is_symlink() or not source.is_file():
        raise ContractError(f"JSON source must be a regular file: {source}")
    try:
        value = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read JSON {source}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError("JSON root must be an object")
    return value


def write_json(path: Path | str, value: Any) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(canonical_json(value))


def require_new_file(path: Path | str, label: str, forbidden: tuple[Path, ...] = ()) -> Path:
    target = Path(path)
    if target.exists() or target.is_symlink() or target.parent.is_symlink() or not target.parent.is_dir():
        raise ContractError(f"{label} must be a new file in an existing non-symlink directory")
    resolved = target.resolve()
    if any(resolved == tree or tree in resolved.parents for tree in forbidden):
        raise ContractError(f"{label} must be outside protected trees")
    return resolved


def require_fresh_directory(path: Path | str, label: str) -> Path:
    target = Path(path)
    if target.exists():
        if target.is_symlink() or not target.is_dir() or any(target.iterdir()):
            raise ContractError(f"{label} must be a fresh empty non-symlink directory")
    else:
        if target.parent.is_symlink() or not target.parent.is_dir():
            raise ContractError(f"{label} parent must be an existing non-symlink directory")
        target.mkdir()
    return target.resolve()


def require_regular(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"{label} must be a regular file")


def normalized_text_digest(path: Path) -> str:
    """Digest JSON canonically and all other text after normalizing line endings."""
    data = path.read_bytes()
    if path.suffix.lower() == ".json":
        try:
            return sha256(canonical_json(json.loads(data.decode("utf-8"))))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ContractError(f"invalid JSON file in suite: {path}") from error
    return sha256(data.replace(b"\r\n", b"\n").replace(b"\r", b"\n"))


def suite_root(suite_path: Path) -> Path:
    require_regular(suite_path, "suite manifest")
    if suite_path.parent.is_symlink():
        raise ContractError("suite manifest parent must not be a symlink")
    root = suite_path.resolve().parent
    if root.is_symlink():
        raise ContractError("suite root must not be a symlink")
    return root


def validate_suite_manifest(manifest: dict[str, Any], root: Path) -> dict[str, dict[str, str]]:
    schema = read_json(ROOT / "schemas" / "benchmark-suite.schema.json")
    required = set(schema["required"])
    if set(manifest) != required:
        raise ContractError("suite manifest must have exactly the canonical top-level fields")
    if manifest["schemaVersion"] != schema["properties"]["schemaVersion"]["const"]:
        raise ContractError("unsupported suite schemaVersion")
    if manifest["digestMethod"] != schema["properties"]["digestMethod"]["const"]:
        raise ContractError("unsupported suite digestMethod")
    if not isinstance(manifest["suiteId"], str) or not CASE_ID_PATTERN.fullmatch(manifest["suiteId"]):
        raise ContractError("suiteId must be a lowercase-hyphen identifier")
    if manifest["suiteId"] != root.parent.name or manifest["suiteVersion"] != root.name:
        raise ContractError("suite identity must match its producer directory")
    if not is_sha256(manifest["canonicalSuiteDigest"]):
        raise ContractError("canonicalSuiteDigest must be SHA-256")
    cases = manifest["cases"]
    if not isinstance(cases, list) or not cases:
        raise ContractError("suite cases must be a non-empty list")

    declared: dict[str, dict[str, str]] = {}
    for case in cases:
        if not isinstance(case, dict) or set(case) != {"caseId", "split", "taskFamily", "group"}:
            raise ContractError("each suite case must have exactly caseId, split, taskFamily, and group")
        case_id = case["caseId"]
        if not isinstance(case_id, str) or not CASE_ID_PATTERN.fullmatch(case_id):
            raise ContractError("caseId must be a lowercase-hyphen identifier")
        if case_id in declared:
            raise ContractError("caseId must be unique")
        if case["split"] not in SPLITS:
            raise ContractError("case split is not recognized")
        if any(not isinstance(case[field], str) or not case[field] for field in ("taskFamily", "group")):
            raise ContractError("case taskFamily and group must be non-empty strings")
        declared[case_id] = case

    if {entry.name for entry in root.iterdir()} != {"suite.json", "cases"}:
        raise ContractError("suite root has unknown, missing, or misplaced entries")
    cases_directory = root / "cases"
    if cases_directory.is_symlink() or not cases_directory.is_dir():
        raise ContractError("suite cases directory is missing or unsafe")
    actual = {entry.name for entry in cases_directory.iterdir()}
    if actual != set(declared):
        raise ContractError("declared and actual case trees differ")
    lower_names = [name.lower() for name in actual]
    if len(lower_names) != len(set(lower_names)):
        raise ContractError("case names collide on a case-insensitive filesystem")
    return declared


def case_tree(root: Path, case_id: str) -> list[tuple[str, Path]]:
    case_root = root / "cases" / case_id
    if case_root.is_symlink() or not case_root.is_dir():
        raise ContractError("case tree is missing or unsafe")
    required = {
        "candidate/request.md",
        "controller/execution.json",
        "controller/fixture.json",
        "oracle/grade.json",
    }
    entries: list[tuple[str, Path]] = []
    names: set[str] = set()
    for entry in case_root.rglob("*"):
        relative = entry.relative_to(case_root).as_posix()
        if entry.is_symlink():
            raise ContractError("suite case contains a symlink or reparse point")
        if entry.is_dir():
            continue
        permitted = relative in required or relative.startswith("candidate/inputs/") or relative == f"oracle/expected/{case_id}.json"
        if not permitted:
            raise ContractError(f"unknown entry in case tree: {relative}")
        require_regular(entry, relative)
        lowered = relative.lower()
        if lowered in names:
            raise ContractError("case entries collide on a case-insensitive filesystem")
        names.add(lowered)
        entries.append((relative, entry))
    present = {relative for relative, _ in entries}
    if not required.issubset(present):
        raise ContractError("case tree is missing candidate, controller, or oracle files")
    expected_directories = {"candidate", "controller", "oracle"}
    if {item.name for item in case_root.iterdir()} != expected_directories:
        raise ContractError("case tree has unknown or missing top-level entries")
    if {item.name for item in (case_root / "candidate").iterdir()} != {"request.md", "inputs"}:
        raise ContractError("candidate tree has unknown or missing entries")
    if {item.name for item in (case_root / "controller").iterdir()} != {"execution.json", "fixture.json"}:
        raise ContractError("controller tree has unknown or missing entries")
    if {item.name for item in (case_root / "oracle").iterdir()} != {"grade.json", "expected"}:
        raise ContractError("oracle tree has unknown or missing entries")
    if {item.name for item in (case_root / "oracle" / "expected").iterdir()} != {f"{case_id}.json"}:
        raise ContractError("oracle expected tree has unknown or missing entries")
    if not any(relative.startswith("candidate/inputs/") for relative in present):
        raise ContractError("candidate inputs must be non-empty")
    return sorted(entries)


def calculate_suite_digest(manifest: dict[str, Any], root: Path, declared: dict[str, dict[str, str]]) -> str:
    entries: list[dict[str, str]] = []
    for source in sorted(path for _, path in sum((case_tree(root, case_id) for case_id in declared), [])):
        relative = source.relative_to(root).as_posix()
        if source.name == "suite.json":
            continue
        if source.suffix == ".json":
            data = canonical_source_json(read_json(source))
        else:
            data = source.read_bytes().replace(b"\r\n", b"\n")
        entries.append({"path": relative, "sha256": sha256(data)})
    manifest_without_digest = dict(manifest)
    manifest_without_digest.pop("canonicalSuiteDigest", None)
    entries.append({"path": "suite.json", "sha256": sha256(canonical_source_json(manifest_without_digest))})
    return sha256(canonical_source_json(sorted(entries, key=lambda item: item["path"])))


def verify_suite_git_pin(root: Path, git_sha: str) -> None:
    if not is_sha1(git_sha):
        raise ContractError("--git-sha must be a full lowercase Git SHA")
    try:
        repository = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip()
        relative = root.relative_to(Path(repository)).as_posix()
        subprocess.run(["git", "-C", repository, "cat-file", "-e", f"{git_sha}^{{commit}}"], check=True, capture_output=True)
        subprocess.run(["git", "-C", repository, "diff", "--quiet", git_sha, "--", relative], check=True)
        if subprocess.run(["git", "-C", repository, "ls-files", "--others", "--exclude-standard", "--", relative], check=True, capture_output=True, text=True).stdout.strip():
            raise ContractError("suite path has untracked files")
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        raise ContractError("suite path does not exactly match the pinned Git commit") from error


def validate_suite_command(args: argparse.Namespace) -> None:
    suite_path = Path(args.suite)
    root = suite_root(suite_path)
    manifest = read_json(suite_path)
    declared = validate_suite_manifest(manifest, root)
    actual_digest = calculate_suite_digest(manifest, root, declared)
    if manifest["canonicalSuiteDigest"] != actual_digest:
        raise ContractError("canonicalSuiteDigest does not match the canonical source tree")
    git_sha = None
    if args.git_sha:
        git_sha = args.git_sha
        verify_suite_git_pin(root, git_sha)
    result = {
        "suite_id": manifest["suiteId"],
        "suite_version": manifest["suiteVersion"],
        "suite_digest": actual_digest,
        "cases": [
            {"case_key": case_id, "split": case["split"], "task_family": case["taskFamily"], "group": case["group"]}
            for case_id, case in sorted(declared.items())
        ],
    }
    if git_sha:
        result["git_sha"] = git_sha
    write_json(require_new_file(args.output, "suite validation"), result)


def materialize_case_command(args: argparse.Namespace) -> None:
    suite_path = Path(args.suite)
    root = suite_root(suite_path)
    manifest = read_json(suite_path)
    declared = validate_suite_manifest(manifest, root)
    actual_digest = calculate_suite_digest(manifest, root, declared)
    if manifest["canonicalSuiteDigest"] != actual_digest:
        raise ContractError("canonicalSuiteDigest does not match the canonical source tree")
    if args.git_sha:
        verify_suite_git_pin(root, args.git_sha)
    case_id = args.case_key
    if case_id not in declared:
        raise ContractError("case_key is not declared by the suite")

    workspace = require_fresh_directory(args.output, "candidate workspace")
    case_root = root / "cases" / case_id
    if workspace == root or root in workspace.parents or case_root in workspace.parents:
        raise ContractError("candidate workspace must be outside the suite and case trees")
    manifest_path = require_new_file(args.manifest_output, "materialization manifest", (workspace, root, case_root))
    sources = dict(case_tree(root, case_id))
    permitted = {relative for relative in sources if relative == "candidate/request.md" or relative.startswith("candidate/inputs/")}
    files: list[dict[str, str]] = []
    for relative in sorted(permitted):
        source = sources.get(relative)
        if source is None:
            raise ContractError("candidate input is missing from the suite")
        destination = workspace / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        files.append({"path": relative, "digest": normalized_text_digest(destination)})
    write_json(manifest_path, {
        "case_key": case_id,
        "suite_digest": actual_digest,
        "git_sha": args.git_sha or None,
        "input_digest": sha256(canonical_json(files)),
        "files": files,
    })


def definition_errors(definition: Any) -> list[str]:
    if not isinstance(definition, dict):
        return ["Definition must be an object"]
    missing = [field for field in REQUIRED_DEFINITION if field not in definition]
    if missing:
        return ["Definition is missing " + ", ".join(missing)]
    unknown = set(definition) - set(REQUIRED_DEFINITION)
    if unknown:
        return ["Definition has unknown fields: " + ", ".join(sorted(unknown))]

    errors: list[str] = []
    if definition["selection_locked"] is not True:
        errors.append("selection_locked must be true")
    if definition["use_kind"] not in USE_KINDS or definition["experiment_purpose"] not in PURPOSES:
        errors.append("use_kind or experiment_purpose is invalid")
    if not isinstance(definition["definition_id"], str) or not definition["definition_id"]:
        errors.append("definition_id is invalid")
    if not isinstance(definition["hypothesis"], str) or not definition["hypothesis"]:
        errors.append("hypothesis is invalid")

    suite = definition["suite"]
    if not isinstance(suite, dict) or not all(isinstance(suite.get(field), str) and suite[field] for field in ("id", "version", "repository")):
        errors.append("suite requires id, version, and repository")
    elif set(suite) != SUITE_DEFINITION_FIELDS:
        errors.append("suite has unknown or missing fields")
    elif not is_sha1(suite.get("git_sha")) or not is_sha256(suite.get("digest")):
        errors.append("suite requires a full lowercase Git SHA and SHA-256 digest")
    else:
        errors.extend(validate_suite_artifact_reference(suite, definition.get("cases")))

    metric = definition["primary_metric"]
    if not isinstance(metric, dict) or not isinstance(metric.get("metric_id"), str) or metric.get("favorable_direction") not in {"higher", "lower"}:
        errors.append("primary_metric requires an id and favorable direction")
    elif set(metric) != PRIMARY_METRIC_FIELDS:
        errors.append("primary_metric has unknown or missing fields")
    elif not isinstance(metric.get("practical_minimum_difference"), (int, float)) or isinstance(metric["practical_minimum_difference"], bool) or metric["practical_minimum_difference"] < 0:
        errors.append("practical_minimum_difference must be non-negative")

    cases = definition["cases"]
    case_keys: set[str] = set()
    groups: set[str] = set()
    if not isinstance(cases, list) or not cases:
        errors.append("cases must be a non-empty list")
    else:
        for case in cases:
            if not isinstance(case, dict) or not isinstance(case.get("case_key"), str) or not case["case_key"] or not isinstance(case.get("independence_group"), str) or not case["independence_group"]:
                errors.append("every case requires case_key and independence_group")
                break
            if set(case) != CASE_DEFINITION_FIELDS:
                errors.append("case has unknown or missing fields")
                break
            if case["case_key"] in case_keys or case["independence_group"] in groups:
                errors.append("case_key and independence_group must each be unique")
                break
            case_keys.add(case["case_key"])
            groups.add(case["independence_group"])

    configurations = definition["configurations"]
    variant_ids: set[str] = set()
    if not isinstance(configurations, list) or not configurations:
        errors.append("configurations must be a non-empty list")
    else:
        for configuration in configurations:
            fields = ("variant_id", "component_digests", "model", "reasoning_effort", "effective_configuration")
            if not isinstance(configuration, dict) or any(field not in configuration for field in fields):
                errors.append("configuration is incomplete")
                break
            if set(configuration) != CONFIGURATION_FIELDS:
                errors.append("configuration has unknown or missing fields")
                break
            if not isinstance(configuration["variant_id"], str) or not CASE_ID_PATTERN.fullmatch(configuration["variant_id"]) or configuration["variant_id"] in variant_ids:
                errors.append("variant_id must be unique")
                break
            if not isinstance(configuration["component_digests"], list) or not configuration["component_digests"] or not all(is_sha256(value) for value in configuration["component_digests"]):
                errors.append("component_digests must be SHA-256 values")
                break
            if not isinstance(configuration["model"], str) or not configuration["model"] or not isinstance(configuration["reasoning_effort"], str) or not configuration["reasoning_effort"] or not isinstance(configuration["effective_configuration"], dict):
                errors.append("configuration model, reasoning_effort, and effective_configuration are required")
                break
            variant_ids.add(configuration["variant_id"])
    if definition["reference_variant_id"] not in variant_ids:
        errors.append("reference_variant_id must select a configuration")

    if not isinstance(definition["replicate_count"], int) or isinstance(definition["replicate_count"], bool) or definition["replicate_count"] < 1:
        errors.append("replicate_count must be a positive integer")
    elif definition["use_kind"] == "formal-comparison" and definition["replicate_count"] < 3:
        errors.append("formal-comparison requires at least three replicates")
    if not isinstance(definition["seed"], int) or isinstance(definition["seed"], bool):
        errors.append("seed must be an integer")
    for field in ("fixed_factors", "pairing_rule", "aggregation_rule", "exclusion_rule", "missingness_rule", "budget", "stop_conditions"):
        if not isinstance(definition[field], dict) or not definition[field]:
            errors.append(f"{field} must be a non-empty object")
    if not isinstance(definition["execution_order"], str) or not definition["execution_order"]:
        errors.append("execution_order is required")
    if not isinstance(definition["required_evidence"], list) or not definition["required_evidence"]:
        errors.append("required_evidence must be a non-empty list")
    elif not all(isinstance(item, str) and item for item in definition["required_evidence"]):
        errors.append("required_evidence entries must be non-empty strings")
    evidence_producers = definition["evidence_producers"]
    if not isinstance(evidence_producers, dict) or set(evidence_producers) != {"execution", "grade"} or not all(producer_is_valid(value) for value in evidence_producers.values()):
        errors.append("evidence_producers must freeze valid execution and Grade producers")

    plan = definition["measurement_plan"]
    if not isinstance(plan, dict) or set(plan) != MEASUREMENT_AXES:
        errors.append("measurement_plan must declare every separate measurement axis")
    elif any(not isinstance(specification, dict) or not specification.get("metric_id") for specification in plan.values()):
        errors.append("every measurement axis requires a metric_id")
    elif any(
        not MEASUREMENT_SPECIFICATION_FIELDS.issubset(specification)
        or bool(set(specification) - (MEASUREMENT_SPECIFICATION_FIELDS | ({"pareto_selected"} if axis in {"provider-reported-cost", "derived-cost"} else set())))
        or ("pareto_selected" in specification and not isinstance(specification["pareto_selected"], bool))
        for axis, specification in plan.items()
    ):
        errors.append("measurement specifications have unknown or missing fields")
    elif any(not isinstance(specification.get("unit"), str) or not specification["unit"] or specification.get("aggregation") != "mean" for specification in plan.values()):
        errors.append("every measurement axis requires a unit and implemented mean aggregation")
    elif definition["experiment_purpose"] == "model-effort-comparison" and sum(specification.get("pareto_selected") is True for axis, specification in plan.items() if axis in {"provider-reported-cost", "derived-cost"}) != 1:
        errors.append("model-effort comparison requires exactly one selected Pareto cost axis")
    if definition.get("aggregation_rule") != {"replicates": "mean", "unit": "case-paired"}:
        errors.append("aggregation_rule must be the implemented mean case-paired rule")

    grader = definition["grader"]
    if not isinstance(grader, dict) or any(not grader.get(field) for field in GRADE_PROVENANCE):
        errors.append("grader requires complete Grade provenance")
    elif set(grader) != set(GRADE_PROVENANCE):
        errors.append("grader has unknown or missing fields")
    elif not isinstance(grader["evidence_refs"], list) or not all(isinstance(item, str) and item for item in grader["evidence_refs"]):
        errors.append("grader evidence_refs must be a non-empty list")
    elif grader.get("kind") == "llm-judge" and grader.get("calibration") != "calibrated":
        errors.append("uncalibrated LLM judge cannot determine primary metric or hard gates")
    for boundary_name in ("candidate_boundary", "controller_boundary", "oracle_boundary"):
        boundary = definition[boundary_name]
        if not isinstance(boundary, dict) or any(not boundary.get(field) for field in ("identity", "access", "evidence")):
            errors.append(f"{boundary_name} requires identity, access, and evidence")
        elif set(boundary) != BOUNDARY_FIELDS:
            errors.append(f"{boundary_name} has unknown or missing fields")
    candidate_boundary = definition["candidate_boundary"]
    if definition["use_kind"] == "formal-comparison" and isinstance(candidate_boundary, dict) and isinstance(candidate_boundary.get("access"), str):
        if any(forbidden in candidate_boundary["access"].lower() for forbidden in ("suite", "controller", "oracle")):
            errors.append("formal candidate boundary may not access suite, controller, or oracle")
    if not isinstance(definition["hard_gates"], dict) or not definition["hard_gates"]:
        errors.append("hard_gates must be non-empty")
    elif any(
        not isinstance(gate_id, str)
        or not CASE_ID_PATTERN.fullmatch(gate_id)
        or not isinstance(gate, dict)
        or set(gate) != {"rule"}
        or not isinstance(gate["rule"], str)
        or not gate["rule"]
        for gate_id, gate in definition["hard_gates"].items()
    ):
        errors.append("each hard gate must have a lowercase-hyphen id and one non-empty rule")

    if isinstance(configurations, list) and configurations:
        effective = {json.dumps(item["effective_configuration"], sort_keys=True) for item in configurations if isinstance(item, dict) and "effective_configuration" in item}
        components = {json.dumps(item["component_digests"], sort_keys=True) for item in configurations if isinstance(item, dict) and "component_digests" in item}
        models = {item.get("model") for item in configurations if isinstance(item, dict)}
        efforts = {item.get("reasoning_effort") for item in configurations if isinstance(item, dict)}
        if definition["experiment_purpose"] == "change-regression":
            if len(models) != 1 or len(efforts) != 1 or len(effective) != 1 or len(components) < 2:
                errors.append("change-regression must vary only component digests")
        if definition["experiment_purpose"] == "model-effort-comparison":
            if len(components) != 1 or len(effective) != 1 or len({(item.get("model"), item.get("reasoning_effort")) for item in configurations}) < 2:
                errors.append("model-effort-comparison must vary model or reasoning_effort only")
            if len({(item.get("model"), item.get("reasoning_effort")) for item in configurations}) != len(configurations):
                errors.append("model-effort configurations must have unique model and reasoning-effort pairs")
    return errors


def validate_suite_artifact_reference(suite: dict[str, Any], definition_cases: Any) -> list[str]:
    path = suite.get("validation_artifact_path")
    expected = suite.get("validation_artifact_digest")
    if not isinstance(path, str) or not os.path.isabs(path) or not is_sha256(expected):
        return ["suite validation artifact absolute path and SHA-256 are required"]
    try:
        artifact_path = Path(path)
        require_regular(artifact_path, "suite validation artifact")
        if sha256(artifact_path.read_bytes()) != expected:
            return ["suite validation artifact digest differs from Definition"]
        artifact = read_json(artifact_path)
    except ContractError:
        return ["suite validation artifact cannot be read"]
    if set(artifact) != {"suite_id", "suite_version", "suite_digest", "git_sha", "cases"}:
        return ["suite validation artifact has unknown or missing fields"]
    if artifact.get("suite_id") != suite.get("id") or artifact.get("suite_version") != suite.get("version") or artifact.get("suite_digest") != suite.get("digest") or artifact.get("git_sha") != suite.get("git_sha") or not isinstance(artifact.get("cases"), list):
        return ["suite validation artifact does not match Definition suite identity"]
    if any(
        not isinstance(item, dict)
        or set(item) != {"case_key", "split", "task_family", "group"}
        or not isinstance(item["case_key"], str)
        or item["split"] not in SPLITS
        or not isinstance(item["task_family"], str)
        or not item["task_family"]
        or not isinstance(item["group"], str)
        or not item["group"]
        for item in artifact["cases"]
    ):
        return ["suite validation artifact cases are invalid"]
    artifact_cases = {item["case_key"]: item for item in artifact["cases"]}
    if len(artifact_cases) != len(artifact["cases"]):
        return ["suite validation artifact case keys are not unique"]
    if not isinstance(definition_cases, list) or any(not isinstance(item, dict) or not isinstance(item.get("case_key"), str) or not isinstance(item.get("independence_group"), str) for item in definition_cases):
        return ["Definition cases cannot be matched to the suite validation artifact"]
    if set(artifact_cases) != {item["case_key"] for item in definition_cases}:
        return ["suite validation artifact case set does not match Definition cases"]
    if any(artifact_cases[item["case_key"]]["group"] != item["independence_group"] for item in definition_cases):
        return ["Definition independence groups differ from the validated suite"]
    return []


def digest_record(record: dict[str, Any]) -> str:
    """Exclude volatile import access timestamps and report environments from identity."""
    ignored = {"record_digest", "validation", "created_at", "accessed_at", "venv", "report_environment"}

    def stable(value: Any) -> Any:
        if isinstance(value, dict):
            return {key: stable(item) for key, item in value.items() if key not in ignored}
        if isinstance(value, list):
            return [stable(item) for item in value]
        return value

    return sha256(canonical_json(stable(record)))


def run_claim_projection(run: dict[str, Any]) -> dict[str, Any]:
    excluded = {"execution_evidence_path", "execution_evidence_digest"}
    return {field: run[field] for field in sorted(RUN_FIELDS - excluded) if field in run}


def grade_claim_projection(grade: dict[str, Any]) -> dict[str, Any]:
    excluded = {"grade_evidence_path", "grade_evidence_digest"}
    return {field: grade[field] for field in sorted(GRADE_FIELDS - excluded) if field in grade}


def read_evidence_artifact(subject: dict[str, Any], path_field: str, digest_field: str, label: str) -> tuple[dict[str, Any] | None, list[str], list[str]]:
    path = subject.get(path_field)
    expected_digest = subject.get(digest_field)
    if not isinstance(path, str) or not os.path.isabs(path) or not is_sha256(expected_digest):
        return None, [], [f"{label} absolute path and SHA-256 are missing"]
    try:
        source = Path(path)
        require_regular(source, label)
        if sha256(source.read_bytes()) != expected_digest:
            return None, [f"{label} digest differs from its producer artifact"], []
        return read_json(source), [], []
    except ContractError:
        return None, [], [f"{label} cannot be read"]


def producer_is_valid(producer: Any) -> bool:
    return (
        isinstance(producer, dict)
        and set(producer) == PRODUCER_FIELDS
        and producer.get("kind") in PRODUCER_KINDS
        and isinstance(producer.get("identity"), str)
        and bool(producer["identity"])
        and isinstance(producer.get("version_or_digest"), str)
        and bool(producer["version_or_digest"])
    )


def run_evidence_errors(run: dict[str, Any], expected_producer: dict[str, Any]) -> tuple[list[str], list[str]]:
    artifact, invalid, incomplete = read_evidence_artifact(
        run,
        "execution_evidence_path",
        "execution_evidence_digest",
        "execution evidence",
    )
    if artifact is None:
        return invalid, incomplete
    if set(artifact) != RUN_EVIDENCE_FIELDS or artifact.get("schema_version") != SCHEMA_VERSION:
        return ["execution evidence has unknown, missing, or unsupported fields"], incomplete
    if not producer_is_valid(artifact.get("producer")):
        invalid.append("execution evidence producer is invalid")
    elif artifact["producer"] != expected_producer:
        invalid.append("execution evidence producer differs from the frozen Definition")
    if artifact.get("subject_id") != run.get("run_id") or artifact.get("claim_digest") != sha256(canonical_json(run_claim_projection(run))):
        invalid.append("execution evidence does not bind the Run claims")
    expected_source_refs = [{"source_digest": run.get("source_digest"), "event_locator": run.get("event_locator")}]
    if artifact.get("source_refs") != expected_source_refs:
        invalid.append("execution evidence does not bind the imported event locator")
    audit = artifact.get("access_audit")
    if not isinstance(audit, dict) or set(audit) != ACCESS_AUDIT_FIELDS:
        invalid.append("execution evidence access audit is invalid")
    else:
        for field in ("suite_access", "controller_access", "oracle_access", "gold_access"):
            if not isinstance(audit.get(field), bool) or audit[field] is not False or run.get(field) is not False:
                invalid.append("execution evidence records candidate access to a protected boundary")
                break
        evidence_refs = audit.get("evidence_refs")
        if not isinstance(evidence_refs, list) or not evidence_refs or not all(isinstance(item, str) and item for item in evidence_refs) or run.get("candidate_access_audit_evidence") not in evidence_refs:
            incomplete.append("execution evidence access audit references are incomplete")
    return invalid, incomplete


def grade_evidence_errors(grade: dict[str, Any], expected_producer: dict[str, Any]) -> tuple[list[str], list[str]]:
    artifact, invalid, incomplete = read_evidence_artifact(
        grade,
        "grade_evidence_path",
        "grade_evidence_digest",
        "Grade evidence",
    )
    if artifact is None:
        return invalid, incomplete
    if set(artifact) != GRADE_EVIDENCE_FIELDS or artifact.get("schema_version") != SCHEMA_VERSION:
        return ["Grade evidence has unknown, missing, or unsupported fields"], incomplete
    producer = artifact.get("producer")
    if not producer_is_valid(producer):
        invalid.append("Grade evidence producer is invalid")
    elif producer != expected_producer:
        invalid.append("Grade evidence producer differs from the frozen Definition")
    elif producer["identity"] != grade.get("producer") or producer["version_or_digest"] != grade.get("version_or_digest"):
        invalid.append("Grade evidence producer differs from Grade provenance")
    if artifact.get("subject_id") != grade.get("grade_id") or artifact.get("claim_digest") != sha256(canonical_json(grade_claim_projection(grade))):
        invalid.append("Grade evidence does not bind the Grade claims")
    if artifact.get("evidence_refs") != grade.get("evidence_refs"):
        invalid.append("Grade evidence refs differ from Grade provenance")
    return invalid, incomplete


def init_command(args: argparse.Namespace) -> None:
    definition = read_json(args.definition)
    errors = definition_errors(definition)
    if errors:
        raise ContractError("; ".join(errors))
    output = require_fresh_directory(args.output, "record output")
    record = {"schema_version": SCHEMA_VERSION, "benchmark_definition": definition, "imports": [], "runs": [], "grades": [], "state": "planned"}
    record["record_digest"] = digest_record(record)
    write_json(output / "benchmark_definition.json", definition)
    write_json(output / "benchmark_record.json", record)


def import_codex_command(args: argparse.Namespace) -> None:
    record_path = Path(args.record)
    record = read_json(record_path)
    source = Path(args.jsonl).resolve()
    require_regular(source, "JSONL source")
    events: list[dict[str, Any]] = []
    types: Counter[str] = Counter()
    offset = 0
    try:
        for line_number, line in enumerate(source.read_bytes().splitlines(keepends=True), 1):
            body = line.strip()
            if body:
                event = json.loads(body)
                event_type = str(event.get("type", "unknown")) if isinstance(event, dict) else "unknown"
                events.append({"line": line_number, "byte_offset": offset, "digest": sha256(body), "type": event_type})
                types[event_type] += 1
            offset += len(line)
    except json.JSONDecodeError as error:
        raise ContractError(f"JSONL source is invalid: {error}") from error
    imported = {
        "absolute_path": str(source),
        "source_digest": sha256(source.read_bytes()),
        "event_locators": events,
        "coverage": {"status": "complete", "event_count": len(events), "event_types": dict(sorted(types.items())), "missing_scopes": []},
        "accessed_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
    }
    imports = record.setdefault("imports", [])
    if not any(item.get("source_digest") == imported["source_digest"] for item in imports if isinstance(item, dict)):
        imports.append(imported)
    record["record_digest"] = digest_record(record)
    write_json(record_path, record)


def grade_errors(grade: Any) -> tuple[list[str], list[str]]:
    invalid: list[str] = []
    incomplete: list[str] = []
    if not isinstance(grade, dict) or any(not grade.get(field) for field in GRADE_PROVENANCE):
        return invalid, ["Grade provenance is incomplete"]
    if not isinstance(grade.get("evidence_refs"), list) or not grade["evidence_refs"] or not all(isinstance(item, str) and item for item in grade["evidence_refs"]):
        incomplete.append("Grade evidence_refs must be a non-empty list")
    status = grade.get("status")
    grader_failure = grade.get("grader_failure")
    candidate_failure = grade.get("candidate_failure")
    if status not in GRADE_STATUSES:
        invalid.append("Grade status is invalid")
    elif status == "completed" and (grader_failure is not None or candidate_failure is not None):
        invalid.append("completed Grade may not carry grader_failure or candidate_failure")
    elif status == "grader-failure":
        if not grader_failure or candidate_failure is not None:
            invalid.append("grader-failure Grade must identify only the grader failure")
        if grade.get("primary_metric_value") is not None or grade.get("hard_gate_results"):
            invalid.append("grader failure may not be converted into candidate metrics or gate results")
        incomplete.append("grader failure requires a new Grade before comparison")
    elif status == "candidate-failure" and (not candidate_failure or grader_failure is not None):
        invalid.append("candidate-failure Grade must identify only the candidate failure")
    if grade.get("kind") == "llm-judge" and grade.get("calibration") != "calibrated":
        if grade.get("primary_metric_value") is not None or grade.get("hard_gate_results"):
            invalid.append("uncalibrated LLM judge cannot feed primary metric or hard gates")
    return invalid, incomplete


def validate_record(record: dict[str, Any]) -> tuple[str, list[str]]:
    unknown_record_fields = set(record) - RECORD_FIELDS
    if unknown_record_fields:
        return "invalid", ["record contains unknown fields: " + ", ".join(sorted(unknown_record_fields))]
    definition = record.get("benchmark_definition")
    errors = definition_errors(definition)
    if errors:
        return "invalid", errors
    assert isinstance(definition, dict)
    invalid: list[str] = []
    incomplete: list[str] = []
    if record.get("schema_version") != SCHEMA_VERSION:
        invalid.append("record schema_version is invalid")
    cases = {case["case_key"]: case for case in definition["cases"]}
    configurations = {item["variant_id"]: item for item in definition["configurations"]}
    expected = {(case_key, variant_id, replicate) for case_key in cases for variant_id in configurations for replicate in range(1, definition["replicate_count"] + 1)}
    observed: set[tuple[str, str, int]] = set()
    run_ids: set[str] = set()
    attempt_ids: set[str] = set()
    referenced_grade_ids: set[str] = set()
    runs = record.get("runs")
    if not isinstance(runs, list):
        return "invalid", ["runs must be a list"]
    grades = record.get("grades")
    if not isinstance(grades, list):
        return "invalid", ["grades must be a list"]
    grades_by_id: dict[str, dict[str, Any]] = {}
    for grade in grades:
        if not isinstance(grade, dict):
            invalid.append("Grade must be an object")
            continue
        unknown_grade_fields = set(grade) - GRADE_FIELDS
        if unknown_grade_fields:
            invalid.append("Grade contains unknown fields: " + ", ".join(sorted(unknown_grade_fields)))
        if not isinstance(grade.get("grade_id"), str) or not grade["grade_id"] or not isinstance(grade.get("run_id"), str) or not grade["run_id"] or grade["grade_id"] in grades_by_id:
            invalid.append("grades require unique grade_id values")
            continue
        grades_by_id[grade["grade_id"]] = grade

    for run in runs:
        if not isinstance(run, dict):
            invalid.append("run must be an object")
            continue
        unknown_run_fields = set(run) - RUN_FIELDS
        if unknown_run_fields:
            invalid.append("Run contains unknown fields: " + ", ".join(sorted(unknown_run_fields)))
        identity = (run.get("case_key"), run.get("variant_id"), run.get("replicate_index"))
        if not isinstance(run.get("run_id"), str) or not run["run_id"] or run["run_id"] in run_ids:
            invalid.append("Run requires a unique run_id")
        else:
            run_ids.add(run["run_id"])
        if not isinstance(run.get("attempt_id"), str) or not run["attempt_id"] or run["attempt_id"] in attempt_ids or not isinstance(run.get("attempt_index"), int) or isinstance(run["attempt_index"], bool) or run["attempt_index"] != 1:
            invalid.append("Run requires one unique, non-retried Attempt with attempt_index 1")
        else:
            attempt_ids.add(run["attempt_id"])
        if run.get("fixed_factors") != definition["fixed_factors"]:
            invalid.append("Run fixed_factors differs from Definition")
        if not isinstance(identity[2], int) or isinstance(identity[2], bool) or identity[2] < 1:
            invalid.append("replicate_index must be a positive integer")
            continue
        if identity not in expected or identity in observed:
            invalid.append("run identities must be planned, unique case×variant×replicate identities")
            continue
        observed.add(identity)
        configuration = configurations[identity[1]]
        if any(run.get(field) != configuration[field] for field in ("model", "reasoning_effort", "component_digests", "effective_configuration")):
            invalid.append("run effective configuration differs from its fixed variant")
        if not run.get("input_digest") or not run.get("source_digest") or not run.get("event_locator") or not run.get("coverage"):
            incomplete.append("run input/source digest, event locator, or coverage is missing")
        access_values = [run.get(field) for field in ("suite_access", "controller_access", "gold_access", "oracle_access", "posthoc_case_selection")]
        if any(not isinstance(value, bool) for value in access_values) or any(access_values) or run.get("fixed_factor_mapping_valid") is not True:
            invalid.append("Run records an unknown or failed validity boundary")
        evidence_invalid, evidence_incomplete = run_evidence_errors(run, definition["evidence_producers"]["execution"])
        invalid.extend(evidence_invalid)
        incomplete.extend(evidence_incomplete)
        grade_id = run.get("grade_id")
        if isinstance(grade_id, str):
            if grade_id in referenced_grade_ids:
                invalid.append("a Grade may be referenced by only one Run")
            referenced_grade_ids.add(grade_id)
        grade = grades_by_id.get(grade_id) if isinstance(grade_id, str) else None
        if grade is None:
            incomplete.append("Run must reference a top-level Grade by grade_id")
        elif grade.get("run_id") != run.get("run_id"):
            invalid.append("Grade run_id must match the Run that references it")
        elif definition["use_kind"] == "formal-comparison" and grade.get("status") != "grader-failure" and (not isinstance(grade.get("primary_metric_value"), (int, float)) or isinstance(grade.get("primary_metric_value"), bool)):
            incomplete.append("formal Grade requires a numeric primary_metric_value")
        grade_invalid, grade_incomplete = grade_errors(grade)
        invalid.extend(grade_invalid)
        incomplete.extend(grade_incomplete)
        if isinstance(grade, dict):
            evidence_invalid, evidence_incomplete = grade_evidence_errors(grade, definition["evidence_producers"]["grade"])
            invalid.extend(evidence_invalid)
            incomplete.extend(evidence_incomplete)
        if isinstance(grade, dict) and all(grade.get(field) for field in GRADE_PROVENANCE) and any(grade.get(field) != definition["grader"].get(field) for field in GRADE_PROVENANCE):
            invalid.append("Run Grade provenance differs from the frozen Definition grader")
        if definition["use_kind"] == "formal-comparison":
            if run.get("suite_digest") != definition["suite"]["digest"] or run.get("git_sha") != definition["suite"]["git_sha"]:
                invalid.append("Run suite digest or Git SHA differs from the frozen Definition")
            manifest_path = run.get("materialization_manifest_path")
            if not isinstance(manifest_path, str) or not os.path.isabs(manifest_path):
                incomplete.append("Run materialization manifest absolute path is missing")
            else:
                try:
                    manifest_file = Path(manifest_path)
                    require_regular(manifest_file, "Run materialization manifest")
                    manifest = read_json(manifest_file)
                    files = manifest.get("files")
                    valid_files = (
                        isinstance(files, list)
                        and bool(files)
                        and all(
                            isinstance(item, dict)
                            and set(item) == {"path", "digest"}
                            and isinstance(item["path"], str)
                            and (item["path"] == "candidate/request.md" or item["path"].startswith("candidate/inputs/"))
                            and ".." not in Path(item["path"]).parts
                            and is_sha256(item["digest"])
                            for item in files
                        )
                        and len({item["path"] for item in files}) == len(files)
                    )
                    if (
                        set(manifest) != {"case_key", "suite_digest", "git_sha", "input_digest", "files"}
                        or not valid_files
                        or manifest.get("input_digest") != sha256(canonical_json(files))
                        or run.get("materialization_manifest_digest") != sha256(canonical_json(manifest))
                        or manifest.get("case_key") != identity[0]
                        or manifest.get("suite_digest") != definition["suite"]["digest"]
                        or manifest.get("git_sha") != definition["suite"]["git_sha"]
                        or manifest.get("input_digest") != run.get("input_digest")
                    ):
                        invalid.append("Run materialization manifest does not bind case, suite, and input digest")
                except ContractError:
                    incomplete.append("Run materialization manifest cannot be read")
            imported_source = next((item for item in record.get("imports", []) if isinstance(item, dict) and item.get("source_digest") == run.get("source_digest")), None)
            if not isinstance(imported_source, dict):
                incomplete.append("Run source_digest is not imported")
            elif run.get("event_locator") not in imported_source.get("event_locators", []) or run.get("coverage") != imported_source.get("coverage"):
                invalid.append("Run event locator or coverage does not exactly match imported evidence")
            if not run.get("candidate_access_audit_evidence"):
                incomplete.append("Run candidate-only access audit evidence is missing")
        if run.get("status") not in {"completed", "stopped"}:
            incomplete.append("run is unfinished")
        gates = grade.get("hard_gate_results") if isinstance(grade, dict) else None
        if isinstance(grade, dict) and grade.get("status") == "grader-failure":
            pass
        elif gates is None:
            incomplete.append("hard gate results are missing")
        elif not isinstance(gates, dict) or set(gates) != set(definition["hard_gates"]) or any(not isinstance(value, dict) or not isinstance(value.get("passed"), bool) or not value.get("evidence") for value in gates.values()):
            invalid.append("hard gate results do not match the Definition")
        if run.get("derived_cost") is not None:
            needed = ("price_source", "price_version_or_digest", "effective_timestamp", "currency", "billing_unit", "usage_mapping", "formula", "input_refs", "calculation_timestamp")
            if any(not run.get(field) for field in needed):
                incomplete.append("derived cost is unverified because price provenance is incomplete")
        if run.get("provider_cost") is not None and not run.get("provider_cost_evidence"):
            incomplete.append("provider-reported cost is unverified because billing evidence is missing")

    if definition["use_kind"] == "completeness-pilot":
        forbidden = {"primary_value", "quality", "reliability", "generalization", "comparison", "conclusion", "supported", "not-supported", "inconclusive"}
        if any(any(key in run for key in forbidden) for run in runs if isinstance(run, dict)):
            invalid.append("pilot may not contain quality, reliability, comparison, or inference claims")
        for grade in grades_by_id.values():
            dimensions = grade.get("dimension_measurements", [])
            if grade.get("primary_metric_value") is not None or any(isinstance(item, dict) and item.get("metric_id") in {"quality", "reliability"} for item in dimensions) or any(key in grade for key in ("conclusion", "confidence_interval", "comparison")):
                invalid.append("pilot Grade may not contain quality, reliability, or formal conclusion values")
        if invalid:
            return "invalid", invalid
        expected_pilot = {(case_key, variant_id, 1) for case_key in cases for variant_id in configurations}
        if definition["replicate_count"] != 1:
            invalid.append("completeness-pilot requires replicate_count of one")
        if observed != expected_pilot:
            incomplete.append("pilot requires every case×variant Run and Grade")
        if definition["experiment_purpose"] == "model-effort-comparison" and any(
            not isinstance(run.get("derived_cost"), (int, float)) or isinstance(run.get("derived_cost"), bool)
            for run in runs
        ):
            incomplete.append("model-effort pilot requires a public-price derived cost for every Run")
        if set(grades_by_id) != referenced_grade_ids:
            invalid.append("record contains an unused Grade")
        if invalid:
            return "invalid", invalid
        if not record.get("imports") or not runs or incomplete:
            return "incomplete", incomplete or ["pilot requires an import, Run, and Grade"]
        return "pilot-complete", []

    if observed != expected:
        incomplete.append("formal record does not contain every case×variant×replicate Run")
    if len({case["independence_group"] for case in cases.values()}) < 10:
        incomplete.append("formal record requires at least ten independent groups")
    if not record.get("imports"):
        incomplete.append("formal record requires imported raw evidence")
    if set(grades_by_id) != referenced_grade_ids:
        invalid.append("record contains an unused Grade")
    if invalid:
        return "invalid", invalid
    return ("comparison-ready", []) if not incomplete else ("incomplete", incomplete)


def require_stored_record_digest(record: dict[str, Any]) -> None:
    if not is_sha256(record.get("record_digest")) or record["record_digest"] != digest_record(record):
        raise ContractError("stored record_digest does not match the frozen record")


def validate_command(args: argparse.Namespace) -> None:
    path = Path(args.record)
    record = read_json(path)
    state, notes = validate_record(record)
    record["state"] = state
    record["validation"] = {"state": state, "notes": notes}
    record["record_digest"] = digest_record(record)
    write_json(path, record)
    if state == "invalid":
        raise ContractError("; ".join(notes))


def measurement_value(run: dict[str, Any], metric_id: str) -> float | None:
    grade = run.get("_grade", {})
    if metric_id == run.get("primary_metric_id") or ("primary_metric_value" in grade and metric_id == run.get("metric_id")):
        value = grade.get("primary_metric_value")
        return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    for item in [*run.get("measurements", []), *grade.get("dimension_measurements", [])]:
        if isinstance(item, dict) and item.get("metric_id") == metric_id and isinstance(item.get("value"), (int, float)) and not isinstance(item["value"], bool):
            return float(item["value"])
    return None


def bootstrap_case_delta(reference: list[float], candidate: list[float], seed: int) -> tuple[float, float, float]:
    if len(reference) != len(candidate):
        raise ContractError("paired bootstrap needs equal reference and candidate case counts")
    deltas = [right - left for left, right in zip(reference, candidate)]
    generator = random.Random(seed)
    samples = sorted(fmean(deltas[generator.randrange(len(deltas))] for _ in deltas) for _ in range(BOOTSTRAP_RESAMPLES))
    return fmean(deltas), samples[249], samples[9749]


def compare_axis(runs: list[dict[str, Any]], cases: list[str], reference: str, candidate: str, replicate_count: int, metric_id: str, seed: int, favorable_direction: str | None = None) -> dict[str, Any]:
    reference_values: list[float] = []
    candidate_values: list[float] = []
    paired_cases: list[str] = []
    missing: list[str] = []
    missingness: list[dict[str, Any]] = []
    for case_key in cases:
        left: list[float] = []
        right: list[float] = []
        for replicate in range(1, replicate_count + 1):
            matching = {(run["variant_id"]): run for run in runs if run["case_key"] == case_key and run["replicate_index"] == replicate and run["variant_id"] in {reference, candidate}}
            left_value = measurement_value(matching.get(reference, {}), metric_id)
            right_value = measurement_value(matching.get(candidate, {}), metric_id)
            if left_value is None or right_value is None:
                missing.append(case_key)
                missingness.append({
                    "case_key": case_key,
                    "replicate_index": replicate,
                    "reference_missing": left_value is None,
                    "candidate_missing": right_value is None,
                    "reason": "measurement-unverified",
                })
            else:
                left.append(left_value)
                right.append(right_value)
        if len(left) == replicate_count and len(right) == replicate_count:
            reference_values.append(fmean(left))
            candidate_values.append(fmean(right))
            paired_cases.append(case_key)
    result: dict[str, Any] = {
        "metric_id": metric_id,
        "population_case_count": len(cases),
        "replicate_count": replicate_count,
        "case_count": len(reference_values),
        "evidence_coverage": "complete" if len(reference_values) == len(cases) else "partial",
        "missing_cases": sorted(set(missing)),
        "missingness": missingness,
        "exclusions": [],
        "case_values": [],
    }
    if reference_values:
        raw_reference = list(reference_values)
        raw_candidate = list(candidate_values)
        if favorable_direction == "lower":
            reference_values = [-value for value in reference_values]
            candidate_values = [-value for value in candidate_values]
        estimate, lower, upper = bootstrap_case_delta(reference_values, candidate_values, seed)
        result.update({"estimate": estimate, "confidence_interval_95": [lower, upper], "resamples": BOOTSTRAP_RESAMPLES,
                       "case_values": [{"case_key": key, "reference": raw_left, "candidate": raw_right, "raw_delta": raw_right - raw_left, "oriented_delta": right - left} for key, raw_left, raw_right, left, right in zip(paired_cases, raw_reference, raw_candidate, reference_values, candidate_values)]})
    return result


def build_comparison(record: dict[str, Any], reference: str, candidate: str) -> dict[str, Any]:
    definition = record["benchmark_definition"]
    configurations = {item["variant_id"] for item in definition["configurations"]}
    if reference != definition["reference_variant_id"] or candidate not in configurations or candidate == reference:
        raise ContractError("comparison must use the preregistered reference and one distinct candidate")
    cases = [case["case_key"] for case in definition["cases"]]
    selected_runs = [run for run in record["runs"] if run["variant_id"] in {reference, candidate}]
    grades = {grade["grade_id"]: grade for grade in record["grades"] if isinstance(grade, dict) and isinstance(grade.get("grade_id"), str)}
    selected_runs = [dict(run, _grade=grades.get(run["grade_id"], {})) for run in selected_runs]
    case_coverage: list[dict[str, Any]] = []
    for case_key in cases:
        for variant in (reference, candidate):
            matching = [run for run in selected_runs if run["case_key"] == case_key and run["variant_id"] == variant]
            case_coverage.append({
                "case_key": case_key,
                "variant_id": variant,
                "planned_runs": definition["replicate_count"],
                "observed_attempts": len(matching),
                "grade_status_counts": dict(sorted(Counter(run["_grade"].get("status", "unverified") for run in matching).items())),
                "status": "complete" if len(matching) == definition["replicate_count"] else "incomplete",
            })
    primary = definition["primary_metric"]
    axes: list[dict[str, Any]] = []
    for axis, specification in definition["measurement_plan"].items():
        metric_id = specification["metric_id"]
        axes.append(compare_axis(selected_runs, cases, reference, candidate, definition["replicate_count"], metric_id, definition["seed"], primary["favorable_direction"] if metric_id == primary["metric_id"] else None) | {"axis": axis, "unit": specification["unit"], "aggregation": specification["aggregation"]})
    primary_result = next((item for item in axes if item["metric_id"] == primary["metric_id"]), None)
    if primary_result is None or primary_result["case_count"] != len(cases):
        raise ContractError("primary metric is incomplete for the paired comparison")
    candidate_runs = [run for run in selected_runs if run["variant_id"] == candidate]
    hard_gate_results = {
        gate: {
            "passed": all(run["_grade"]["hard_gate_results"][gate]["passed"] for run in candidate_runs),
            "evaluated_run_count": len(candidate_runs),
            "rule_digest": sha256(canonical_json(rule)),
        }
        for gate, rule in definition["hard_gates"].items()
    }
    gates_passed = all(result["passed"] for result in hard_gate_results.values())
    grade_status_counts = {
        variant: dict(sorted(Counter(run["_grade"].get("status", "unverified") for run in selected_runs if run["variant_id"] == variant).items()))
        for variant in (reference, candidate)
    }
    selected_source_digests = sorted({run["source_digest"] for run in selected_runs})
    evidence_coverage = {
        "required_evidence_count": len(definition["required_evidence"]),
        "source_digests": selected_source_digests,
        "imported_source_count": len({item.get("source_digest") for item in record["imports"] if isinstance(item, dict) and item.get("source_digest") in selected_source_digests}),
        "run_evidence_verified": len(selected_runs),
        "grade_evidence_verified": len(selected_runs),
        "coverage_status_counts": dict(sorted(Counter(run["coverage"].get("status", "unverified") for run in selected_runs).items())),
        "producers": {
            role: {
                "kind": producer["kind"],
                "identity_digest": sha256(producer["identity"].encode("utf-8")),
                "version_or_digest": producer["version_or_digest"],
            }
            for role, producer in definition["evidence_producers"].items()
        },
    }
    lower, upper = primary_result["confidence_interval_95"]
    pmd = primary["practical_minimum_difference"]
    conclusion = "not-supported" if not gates_passed or upper < pmd else "supported" if lower >= pmd else "inconclusive"
    grader = definition["grader"]
    comparison_id = sha256(canonical_json({
        "definition_id": definition["definition_id"],
        "record_digest": record["record_digest"],
        "reference_variant_id": reference,
        "candidate_variant_id": candidate,
    }))
    return {
        "state": "complete",
        "comparison_id": comparison_id,
        "definition_id": definition["definition_id"],
        "record_digest": record["record_digest"],
        "reference_variant_id": reference,
        "candidate_variant_id": candidate,
        "case_outer_unit": True,
        "resamples": BOOTSTRAP_RESAMPLES,
        "bootstrap": {"method": "paired-bootstrap", "unit": "case", "replicate_aggregation": "mean"},
        "eligibility": {"formal": True, "single_observation": False, "status": "eligible"},
        "primary_metric": primary["metric_id"],
        "practical_minimum_difference": pmd,
        "hard_gates_passed": gates_passed,
        "hard_gate_results": hard_gate_results,
        "grade_status_counts": grade_status_counts,
        "case_coverage": case_coverage,
        "evidence_coverage": evidence_coverage,
        "grader": {
            field: grader[field]
            for field in ("kind", "version_or_digest", "blind_state", "calibration", "adjudication", "producer")
        },
        "axes": axes,
        "exclusions": [],
        "exclusion_rule_digest": sha256(canonical_json(definition["exclusion_rule"])),
        "re_evaluation_triggers": [
            "record-digest-changed",
            "suite-pin-changed",
            "grader-version-or-digest-changed",
            "hard-gate-rule-changed",
            "missing-evidence-resolved",
        ],
        "conclusion": conclusion,
        "conclusion_basis": {
            "confidence_interval_95": primary_result["confidence_interval_95"],
            "practical_minimum_difference": pmd,
            "hard_gates_passed": gates_passed,
        },
    }


def compare_command(args: argparse.Namespace) -> None:
    record = read_json(args.record)
    require_stored_record_digest(record)
    state, notes = validate_record(record)
    if state != "comparison-ready":
        raise ContractError("comparison requires a comparison-ready frozen record: " + ", ".join(notes))
    output = build_comparison(record, args.reference_variant, args.candidate_variant)
    write_json(require_new_file(args.output, "comparison output"), output)


def setup_report_command(args: argparse.Namespace) -> None:
    if sys.version_info[:2] != (3, 12):
        raise ContractError("setup-report requires Python 3.12")
    output = require_fresh_directory(args.output, "report environment")
    environment = output / ".report-venv"
    venv.EnvBuilder(with_pip=True).create(environment)
    python = environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(ROOT / "requirements-report.txt")], check=True)
    check = subprocess.run([str(python), "-c", "import matplotlib, numpy; matplotlib.use('Agg'); assert matplotlib.__version__ == '3.11.1'; assert numpy.__version__ == '2.5.2'; print(matplotlib.get_backend())"], check=True, capture_output=True, text=True)
    packages = subprocess.run([str(python), "-m", "pip", "freeze"], check=True, capture_output=True, text=True).stdout.splitlines()
    write_json(output / "report_environment.json", {"python": str(python), "matplotlib": "3.11.1", "numpy": "2.5.2", "backend": check.stdout.strip(), "packages": packages})


def report_rows(record: dict[str, Any]) -> list[dict[str, Any]]:
    definition = record["benchmark_definition"]
    opaque = {case["case_key"]: f"case-{index:03d}" for index, case in enumerate(sorted(definition["cases"], key=lambda item: item["case_key"]), 1)}
    plan = definition["measurement_plan"]
    fields = ("variant_id", "replicate_index", *sorted(plan))
    rows: list[dict[str, Any]] = []
    grades = {grade["grade_id"]: grade for grade in record["grades"] if isinstance(grade, dict) and isinstance(grade.get("grade_id"), str)}
    for stored_run in record["runs"]:
        run = dict(stored_run, _grade=grades.get(stored_run.get("grade_id"), {}))
        row = {"case_key": opaque[run["case_key"]]}
        row["status"] = run.get("status") if run.get("status") in {"completed", "stopped"} else "unverified"
        row["grade_status"] = run["_grade"].get("status") if run["_grade"].get("status") in GRADE_STATUSES else "unverified"
        gate_results = run["_grade"].get("hard_gate_results")
        if isinstance(gate_results, dict) and all(
            isinstance(gate_results.get(gate), dict)
            and isinstance(gate_results[gate].get("passed"), bool)
            for gate in definition["hard_gates"]
        ):
            row["hard_gate_failures"] = sum(
                not gate_results[gate]["passed"] for gate in definition["hard_gates"]
            )
            row["hard_gate_total"] = len(definition["hard_gates"])
        for field in fields:
            if field in plan:
                value = measurement_value(run, plan[field]["metric_id"])
            else:
                value = run.get(field)
            if isinstance(value, (str, int, float, bool)) or value is None:
                row[field] = value
        rows.append(row)
    return rows


def save_pilot_figure(figure: Any, output: Path, name: str, title: str, description: str) -> list[str]:
    result = []
    figure.tight_layout()
    for extension in ("svg", "png"):
        target = output / f"{name}.{extension}"
        figure.savefig(
            target,
            metadata={"Date": None, "Title": title, "Description": description},
        )
        result.append(f"charts/{target.name}")
    return result


def pilot_grid(rows: list[dict[str, Any]], variants: list[str]) -> tuple[list[str], dict[tuple[str, str], dict[str, Any]]]:
    cases = sorted({str(row["case_key"]) for row in rows})
    indexed = {(str(row["case_key"]), str(row["variant_id"])): row for row in rows}
    expected = {(case, variant) for case in cases for variant in variants}
    if set(indexed) != expected:
        raise ContractError("pilot charts require exactly one Run for every opaque case and variant")
    return cases, indexed


def draw_pilot_grade_status(plt: Any, output: Path, rows: list[dict[str, Any]], variants: list[str]) -> list[str]:
    cases, indexed = pilot_grid(rows, variants)
    status_codes = {"completed": 0, "candidate-failure": 1, "grader-failure": 2, "unverified": 3}
    status_labels = {
        "completed": "completed",
        "candidate-failure": "candidate\nfailure",
        "grader-failure": "grader\nfailure",
        "unverified": "unverified",
    }
    matrix = [
        [status_codes.get(str(indexed[(case, variant)].get("grade_status")), 3) for variant in variants]
        for case in cases
    ]
    title = "Pilot Grade status\nn=1 per case × variant · descriptive only"
    figure, axis = plt.subplots(figsize=(max(6.4, len(variants) * 1.65), max(4.2, len(cases) * 0.55 + 2.4)))
    axis.set_gid("pilot-grade-status")
    axis.imshow(matrix, cmap="cividis", vmin=0, vmax=3, aspect="auto")
    for row_index, case in enumerate(cases):
        for column_index, variant in enumerate(variants):
            status = str(indexed[(case, variant)].get("grade_status", "unverified"))
            label = status_labels.get(status, "unverified")
            text = axis.text(
                column_index,
                row_index,
                label,
                ha="center",
                va="center",
                color="white" if status_codes.get(status, 3) < 2 else "black",
                fontsize=8,
            )
            text.set_gid(f"pilot-grade-status-{case}-{variant}-{status}")
    axis.set_xticks(range(len(variants)), variants, rotation=25, ha="right")
    axis.set_yticks(range(len(cases)), cases)
    axis.set(title=title, xlabel="configuration", ylabel="case (opaque)")
    result = save_pilot_figure(
        figure,
        output,
        "pilot-grade-status",
        title,
        "Directly observed Grade status for one Run in each opaque case and configuration. No comparison or inference is shown.",
    )
    plt.close(figure)
    return result


def draw_pilot_hard_gates(plt: Any, output: Path, rows: list[dict[str, Any]], variants: list[str]) -> list[str]:
    cases, indexed = pilot_grid(rows, variants)
    totals = [
        int(indexed[(case, variant)].get("hard_gate_total", 0))
        for case in cases
        for variant in variants
    ]
    failures = [
        [int(indexed[(case, variant)].get("hard_gate_failures", 0)) for variant in variants]
        for case in cases
    ]
    title = "Pilot hard-gate failures\nn=1 per case × variant · descriptive only"
    figure, axis = plt.subplots(figsize=(max(6.4, len(variants) * 1.65), max(4.2, len(cases) * 0.55 + 2.4)))
    axis.set_gid("pilot-hard-gates")
    maximum = max(1, max(totals, default=1))
    image = axis.imshow(failures, cmap="magma", vmin=0, vmax=maximum, aspect="auto")
    for row_index, case in enumerate(cases):
        for column_index, variant in enumerate(variants):
            row = indexed[(case, variant)]
            failed = int(row.get("hard_gate_failures", 0))
            total = int(row.get("hard_gate_total", 0))
            text = axis.text(
                column_index,
                row_index,
                f"{failed}/{total}",
                ha="center",
                va="center",
                color="black" if failed > maximum / 2 else "white",
            )
            text.set_gid(f"pilot-hard-gates-{case}-{variant}-{failed}-of-{total}")
    axis.set_xticks(range(len(variants)), variants, rotation=25, ha="right")
    axis.set_yticks(range(len(cases)), cases)
    axis.set(title=title, xlabel="configuration", ylabel="case (opaque)")
    figure.colorbar(image, ax=axis, label="failed hard gates (count)")
    result = save_pilot_figure(
        figure,
        output,
        "pilot-hard-gates",
        title,
        "Directly observed failed hard-gate count over the registered hard gates for each Run. This is not a formal comparison gate result.",
    )
    plt.close(figure)
    return result


def draw_pilot_measurement_bars(
    plt: Any,
    output: Path,
    rows: list[dict[str, Any]],
    variants: list[str],
    field: str,
    name: str,
    label: str,
    unit: str,
    basis: str | None = None,
) -> list[str]:
    cases, indexed = pilot_grid(rows, variants)
    basis_line = f"\n{basis}" if basis else ""
    title = f"Pilot {label}\nn=1 per case × variant · descriptive only{basis_line}"
    figure, axis = plt.subplots(figsize=(max(8.4, len(cases) * 1.75), 5.2))
    axis.set_gid(name)
    colors = ("#4477AA", "#EE6677", "#228833", "#CCBB44", "#66CCEE", "#AA3377")
    hatches = ("", "//", "xx", "..", "\\\\", "++")
    group_width = 0.82
    bar_width = group_width / max(1, len(variants))
    for variant_index, variant in enumerate(variants):
        offset = (variant_index - (len(variants) - 1) / 2) * bar_width
        observed_cases: list[str] = []
        x_values: list[float] = []
        y_values: list[float] = []
        for case_index, case in enumerate(cases):
            value = indexed[(case, variant)].get(field)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                observed_cases.append(case)
                x_values.append(case_index + offset)
                y_values.append(float(value))
            else:
                text = axis.text(
                    case_index + offset,
                    0,
                    "unverified",
                    ha="center",
                    va="bottom",
                    rotation=90,
                    fontsize=6,
                    color="0.45",
                )
                text.set_gid(f"{name}-{case}-{variant}-unverified")
        bars = axis.bar(
            x_values,
            y_values,
            width=bar_width * 0.92,
            color=colors[variant_index % len(colors)],
            edgecolor="black",
            linewidth=0.45,
            hatch=hatches[variant_index % len(hatches)],
            label=variant,
        )
        for case, bar, value in zip(observed_cases, bars, y_values):
            bar.set_gid(f"{name}-{case}-{variant}-bar")
            value_label = f"${value:.2f}" if unit == "USD" else f"{value:.1f}"
            axis.annotate(
                value_label,
                (bar.get_x() + bar.get_width() / 2, bar.get_height()),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                va="bottom",
                fontsize=6,
                rotation=90,
            )
    axis.set_xticks(range(len(cases)), cases, rotation=25, ha="right")
    axis.set(title=title, xlabel="case (opaque)", ylabel=f"{label} ({unit})")
    axis.set_ylim(bottom=0)
    axis.grid(axis="y", linewidth=0.5, alpha=0.35)
    axis.ticklabel_format(axis="y", style="plain", useOffset=False)
    axis.legend(title="configuration", ncols=min(4, len(variants)), frameon=False)
    result = save_pilot_figure(
        figure,
        output,
        name,
        title,
        f"Grouped bars show {label} for one Run in each opaque case and configuration from a zero baseline. No aggregate, interval, ranking, or inference is shown.",
    )
    plt.close(figure)
    return result


def draw_pilot_performance_cost_curve(
    plt: Any,
    output: Path,
    rows: list[dict[str, Any]],
    configurations: list[dict[str, Any]],
    case_count: int,
    price_basis: str,
) -> list[str]:
    variants = [configuration["variant_id"] for configuration in configurations]
    pilot_grid(rows, variants)
    rows_by_variant = {
        variant: [row for row in rows if row["variant_id"] == variant]
        for variant in variants
    }
    observations: dict[str, list[dict[str, Any]]] = {}
    for configuration in configurations:
        variant = configuration["variant_id"]
        variant_rows = rows_by_variant[variant]
        if len(variant_rows) != case_count or any(
            not isinstance(row.get("derived-cost"), (int, float))
            or isinstance(row.get("derived-cost"), bool)
            for row in variant_rows
        ):
            raise ContractError("pilot performance-cost curve requires one derived-cost observation per case and variant")
        observations[variant] = sorted(
            (
                {
                    "case_key": row["case_key"],
                    "cost": float(row["derived-cost"]),
                    "accepted": row.get("grade_status") == "completed"
                    and isinstance(row.get("hard_gate_failures"), int)
                    and row["hard_gate_failures"] == 0,
                }
                for row in variant_rows
            ),
            key=lambda item: (item["cost"], item["case_key"]),
        )

    title = (
        "Pilot cost–coverage curves by model and reasoning effort\n"
        f"{case_count} cases × n=1 per case/configuration · descriptive only\n{price_basis}"
    )
    figure, axis = plt.subplots(figsize=(8.4, 5.4))
    axis.set_gid("pilot-performance-cost-curve")
    colors = ("#4477AA", "#EE6677", "#228833", "#CCBB44", "#66CCEE", "#AA3377")
    models = sorted({configuration["model"] for configuration in configurations})
    model_colors = {model: colors[index % len(colors)] for index, model in enumerate(models)}
    effort_styles = {
        "none": ("-", "o"),
        "low": ("-", "o"),
        "medium": ("-.", "D"),
        "high": ("-", "o"),
        "xhigh": (":", "^"),
        "max": ("--", "s"),
    }
    all_costs = [observation["cost"] for variant in variants for observation in observations[variant]]
    minimum_cost = min(all_costs)
    maximum_cost = max(all_costs)
    start_cost = minimum_cost * 0.78
    end_cost = maximum_cost * 1.15
    for configuration in configurations:
        variant = configuration["variant_id"]
        color = model_colors[configuration["model"]]
        line_style, marker = effort_styles.get(configuration["reasoning_effort"], ("-", "o"))
        threshold_values = [start_cost]
        accepted_coverage = [0.0]
        accepted_count = 0
        case_points: list[tuple[dict[str, Any], float]] = []
        for observation in observations[variant]:
            if observation["accepted"]:
                accepted_count += 1
            coverage = accepted_count / case_count
            threshold_values.append(observation["cost"])
            accepted_coverage.append(coverage)
            case_points.append((observation, coverage))
        threshold_values.append(end_cost)
        accepted_coverage.append(accepted_count / case_count)
        line, = axis.step(
            threshold_values,
            accepted_coverage,
            where="post",
            color=color,
            linestyle=line_style,
            linewidth=1.8,
            label=f"{configuration['model']} / {configuration['reasoning_effort']}",
        )
        line.set_gid(f"pilot-performance-cost-{variant}-line")
        for observation, coverage in case_points:
            point = axis.scatter(
                [observation["cost"]],
                [coverage],
                facecolor=color if observation["accepted"] else "white",
                edgecolor="black",
                linewidth=0.55,
                marker=marker,
                s=42,
                zorder=3,
            )
            point.set_gid(
                f"pilot-performance-cost-{variant}-{observation['case_key']}-"
                f"{'accepted' if observation['accepted'] else 'not-accepted'}"
            )
    axis.set_xscale("log")
    axis.set_xlim(start_cost, end_cost)
    axis.set_ylim(0, 1.05)
    axis.set_yticks([index / 5 for index in range(6)], [f"{index * 20}%" for index in range(6)])
    axis.set(
        title=title,
        xlabel="public API price estimate threshold per Run (USD, log scale)",
        ylabel="Accepted case coverage within threshold",
    )
    axis.grid(which="both", linewidth=0.5, alpha=0.35)
    axis.legend(title="configuration", frameon=False, loc="upper left")
    marker_key = axis.text(
        0.99,
        0.02,
        "filled marker = Accepted · hollow marker = not Accepted",
        transform=axis.transAxes,
        ha="right",
        va="bottom",
        fontsize=8,
    )
    marker_key.set_gid("pilot-performance-cost-marker-key")
    result = save_pilot_figure(
        figure,
        output,
        "pilot-performance-cost-curve",
        title,
        f"Each model and reasoning-effort configuration is one empirical step line. At each public-price threshold, the line shows the share of the {case_count} registered cases whose Run cost is within the threshold and whose Grade completed with every hard gate passed. Filled case markers are Accepted and hollow markers are not Accepted. The single-observation curve is descriptive and does not imply interpolation, ranking, or a formal quality comparison.",
    )
    plt.close(figure)
    return result


def draw_chart(plt: Any, output: Path, name: str, x: list[float], y: list[float], title: str, x_label: str, y_label: str) -> list[str]:
    figure, axis = plt.subplots()
    axis.scatter(x, y)
    axis.set(title=title, xlabel=x_label, ylabel=y_label)
    paths = []
    for extension in ("svg", "png"):
        target = output / f"{name}.{extension}"
        figure.savefig(target, metadata={"Date": None})
        paths.append(f"charts/{target.name}")
    plt.close(figure)
    return paths


def pareto_frontier(cost_or_time: list[float], quality: list[float]) -> list[tuple[float, float]]:
    """Return maximize-quality/minimize-cost non-dominated points in x order."""
    best_at_x: dict[float, float] = {}
    for x_value, quality_value in zip(cost_or_time, quality):
        best_at_x[x_value] = max(quality_value, best_at_x.get(x_value, float("-inf")))
    frontier: list[tuple[float, float]] = []
    best_quality = float("-inf")
    for x_value in sorted(best_at_x):
        quality_value = best_at_x[x_value]
        if quality_value > best_quality:
            frontier.append((x_value, quality_value))
            best_quality = quality_value
    return frontier


def draw_pareto_chart(
    plt: Any,
    output: Path,
    name: str,
    x: list[float],
    quality: list[float],
    labels: list[str],
    configurations: list[dict[str, Any]],
    title: str,
    x_label: str,
    y_label: str,
) -> list[str]:
    figure, axis = plt.subplots()
    values = {label: (x_value, quality_value) for x_value, quality_value, label in zip(x, quality, labels)}
    colors = ("#4477AA", "#EE6677", "#228833", "#CCBB44", "#66CCEE", "#AA3377")
    markers = ("o", "s", "^", "D", "P", "X")
    models = sorted({configuration["model"] for configuration in configurations})
    for configuration in configurations:
        model_index = models.index(configuration["model"])
        x_value, quality_value = values[configuration["variant_id"]]
        point = axis.scatter(
            [x_value],
            [quality_value],
            color=colors[model_index % len(colors)],
            edgecolor="black",
            linewidth=0.55,
            marker=markers[model_index % len(markers)],
            s=50,
            zorder=3,
            label=f"{configuration['model']} / {configuration['reasoning_effort']}",
        )
        point.set_gid(f"performance-point-{configuration['variant_id']}")
        axis.annotate(configuration["variant_id"], (x_value, quality_value), xytext=(4, 4), textcoords="offset points")
    frontier = pareto_frontier(x, quality)
    if frontier:
        line, = axis.plot(
            [point[0] for point in frontier],
            [point[1] for point in frontier],
            color="0.25",
            linestyle="--",
            linewidth=1.2,
        )
        line.set_gid("pareto-frontier")
    axis.set(title=title, xlabel=x_label, ylabel=y_label)
    axis.grid(linewidth=0.5, alpha=0.35)
    axis.legend(title="configuration", frameon=False)
    result = []
    for extension in ("svg", "png"):
        target = output / f"{name}.{extension}"
        figure.savefig(target, metadata={"Date": None})
        result.append(f"charts/{target.name}")
    plt.close(figure)
    return result


def draw_reliability_chart(plt: Any, output: Path, comparison_axis: dict[str, Any], unit: str) -> list[str]:
    case_values = comparison_axis.get("case_values", [])
    deltas = [float(item["oriented_delta"]) for item in case_values]
    estimate = float(comparison_axis["estimate"])
    lower, upper = [float(value) for value in comparison_axis["confidence_interval_95"]]

    figure, axis = plt.subplots()
    case_points = axis.scatter(range(1, len(deltas) + 1), deltas, label="case delta")
    case_points.set_gid("reliability-case-deltas")
    zero_line = axis.axhline(0.0, linestyle="--", linewidth=1)
    zero_line.set_gid("reliability-zero-reference")
    confidence_band = axis.axhspan(lower, upper, alpha=0.15, label="95% confidence interval")
    confidence_band.set_gid("reliability-confidence-band")
    estimate_line = axis.axhline(estimate, linewidth=1.5, label="paired estimate")
    estimate_line.set_gid("reliability-estimate")
    axis.set(
        title="Reliability paired delta",
        xlabel="case",
        ylabel=f"oriented delta ({unit})",
    )
    axis.legend()

    result = []
    for extension in ("svg", "png"):
        target = output / f"reliability.{extension}"
        figure.savefig(target, metadata={"Date": None})
        result.append(f"charts/{target.name}")
    plt.close(figure)
    return result


def read_svg_fragment(path: Path) -> str:
    source = path.read_text(encoding="utf-8")
    start = source.find("<svg")
    end = source.rfind("</svg>")
    if start < 0 or end < start:
        raise ContractError(f"chart is not a complete SVG document: {path.name}")
    return source[start:end + len("</svg>")]


def report_command(args: argparse.Namespace) -> None:
    if sys.version_info[:2] != (3, 12) or sys.prefix == sys.base_prefix:
        raise ContractError("report must run in an artifact-local Python 3.12 virtual environment")
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy

    matplotlib.rcParams.update({"svg.hashsalt": "agent-benchmarking-v1", "svg.fonttype": "none", "font.family": "DejaVu Sans", "figure.dpi": 120, "savefig.dpi": 120})

    if matplotlib.__version__ != "3.11.1" or numpy.__version__ != "2.5.2" or matplotlib.get_backend().lower() != "agg":
        raise ContractError("report requires pinned Matplotlib, NumPy, and Agg")
    installed_packages = subprocess.run([sys.executable, "-m", "pip", "freeze"], check=True, capture_output=True, text=True).stdout.splitlines()
    record = read_json(args.record)
    require_stored_record_digest(record)
    state, notes = validate_record(record)
    if state not in {"pilot-complete", "comparison-ready"} or record.get("state") != state:
        raise ContractError("report requires a validated pilot-complete or comparison-ready record")
    comparison: dict[str, Any] = {
        "state": "not-applicable",
        "definition_id": record["benchmark_definition"]["definition_id"],
        "record_digest": record["record_digest"],
        "eligibility": {"formal": False, "single_observation": True, "status": "not-eligible"},
        "conclusion": None,
        "re_evaluation_triggers": ["create-formal-comparison-definition"],
    }
    if state == "comparison-ready":
        if not args.comparison:
            raise ContractError("formal report requires its comparison artifact")
        comparison = read_json(args.comparison)
        if comparison.get("record_digest") != record.get("record_digest"):
            raise ContractError("comparison digest does not match the frozen record")
        expected_comparison = build_comparison(
            record,
            comparison.get("reference_variant_id"),
            comparison.get("candidate_variant_id"),
        )
        if canonical_json(comparison) != canonical_json(expected_comparison):
            raise ContractError("comparison artifact is not the deterministic result of the frozen record")

    output = require_fresh_directory(args.output, "report output")
    charts = output / "charts"
    charts.mkdir()
    rows = report_rows(record)
    with (output / "metrics.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=sorted({field for row in rows for field in row}) or ["case_key"])
        writer.writeheader()
        writer.writerows(rows)

    definition = record["benchmark_definition"]
    opaque_cases = {case["case_key"]: f"case-{index:03d}" for index, case in enumerate(sorted(definition["cases"], key=lambda item: item["case_key"]), 1)}
    public_comparison = json.loads(json.dumps(comparison))
    for axis in public_comparison.get("axes", []):
        if isinstance(axis, dict):
            axis["missing_cases"] = [opaque_cases.get(value, "case-unknown") for value in axis.get("missing_cases", [])]
            for item in axis.get("missingness", []):
                if isinstance(item, dict):
                    item["case_key"] = opaque_cases.get(item.get("case_key"), "case-unknown")
            for pair in axis.get("case_values", []):
                if isinstance(pair, dict):
                    pair["case_key"] = opaque_cases.get(pair.get("case_key"), "case-unknown")
    for item in public_comparison.get("case_coverage", []):
        if isinstance(item, dict):
            item["case_key"] = opaque_cases.get(item.get("case_key"), "case-unknown")
    chart_files: list[str] = []
    if state == "pilot-complete":
        variants = [configuration["variant_id"] for configuration in definition["configurations"]]
        chart_files += draw_pilot_grade_status(plt, charts, rows, variants)
        chart_files += draw_pilot_hard_gates(plt, charts, rows, variants)
        chart_files += draw_pilot_measurement_bars(
            plt,
            charts,
            rows,
            variants,
            "time",
            "pilot-elapsed-time",
            "elapsed time",
            definition["measurement_plan"]["time"]["unit"],
        )
        observed_costs = [
            run["derived_cost"]
            for run in record["runs"]
            if isinstance(run.get("derived_cost"), (int, float))
        ]
        effective_dates: set[str] = set()
        for run in record["runs"]:
            timestamp = run.get("effective_timestamp")
            if not isinstance(run.get("derived_cost"), (int, float)) or not isinstance(timestamp, str):
                continue
            candidate_date = timestamp[:10]
            try:
                date.fromisoformat(candidate_date)
            except ValueError:
                continue
            effective_dates.add(candidate_date)
        sorted_effective_dates = sorted(effective_dates)
        if not observed_costs:
            price_basis = "public price estimate unverified"
        elif len(sorted_effective_dates) == 1:
            price_basis = f"public pricing observed {sorted_effective_dates[0]}"
        else:
            price_basis = "price basis in metrics provenance"
        chart_files += draw_pilot_measurement_bars(
            plt,
            charts,
            rows,
            variants,
            "derived-cost",
            "pilot-public-price-cost",
            "public API price estimate",
            definition["measurement_plan"]["derived-cost"]["unit"],
            price_basis,
        )
        if definition["experiment_purpose"] == "model-effort-comparison":
            chart_files += draw_pilot_performance_cost_curve(
                plt,
                charts,
                rows,
                definition["configurations"],
                len(definition["cases"]),
                price_basis,
            )
    elif definition["experiment_purpose"] == "change-regression":
        paired = next((axis.get("case_values", []) for axis in public_comparison.get("axes", []) if axis.get("metric_id") == definition["primary_metric"]["metric_id"]), [])
        deltas = [float(pair["oriented_delta"]) for pair in paired]
        chart_files += draw_chart(plt, charts, "paired-delta", list(range(len(deltas))), deltas, "Paired delta", "case", "delta")
    else:
        provider_specification = definition["measurement_plan"]["provider-reported-cost"]
        derived_specification = definition["measurement_plan"]["derived-cost"]
        selected = [axis for axis, specification in (("provider-reported-cost", provider_specification), ("derived-cost", derived_specification)) if specification.get("pareto_selected") is True]
        if len(selected) != 1:
            raise ContractError("model-effort report requires exactly one explicitly selected cost axis")
        selected_cost = selected[0]
        by_variant: dict[str, dict[str, list[float]]] = {}
        for row in rows:
            variant = row["variant_id"]
            measurements = by_variant.setdefault(variant, {"quality": [], selected_cost: [], "time": []})
            for field in measurements:
                if isinstance(row.get(field), (int, float)):
                    measurements[field].append(float(row[field]))
        aggregate = {
            variant: {field: fmean(values) for field, values in values_by_axis.items() if values}
            for variant, values_by_axis in by_variant.items()
        }
        if any(selected_cost not in values or "quality" not in values or "time" not in values for values in aggregate.values()):
            raise ContractError("selected Pareto cost axis has no observed values")
        figure, axis = plt.subplots()
        efforts = sorted({item["reasoning_effort"] for item in definition["configurations"]})
        models = sorted({item["model"] for item in definition["configurations"]})
        matrix = [[0.0 for _ in efforts] for _ in models]
        for configuration in definition["configurations"]:
            row = models.index(configuration["model"])
            column = efforts.index(configuration["reasoning_effort"])
            value = aggregate[configuration["variant_id"]]["quality"]
            matrix[row][column] = value
            text = axis.text(column, row, f"{value:.3f}", ha="center", va="center")
            text.set_gid(f"heatmap-value-{configuration['variant_id']}")
        image = axis.imshow(matrix)
        axis.set_xticks(range(len(efforts)), efforts)
        axis.set_yticks(range(len(models)), models)
        quality_unit = definition["measurement_plan"]["quality"]["unit"]
        axis.set(title="Metric heatmap", xlabel="reasoning effort", ylabel="model")
        figure.colorbar(image, ax=axis, label=f"quality ({quality_unit})")
        for extension in ("svg", "png"):
            figure.savefig(charts / f"metric-heatmap.{extension}", metadata={"Date": None})
            chart_files.append(f"charts/metric-heatmap.{extension}")
        plt.close(figure)
        costs = [aggregate[item["variant_id"]][selected_cost] for item in definition["configurations"]]
        qualities = [aggregate[item["variant_id"]]["quality"] for item in definition["configurations"]]
        elapsed = [aggregate[item["variant_id"]]["time"] for item in definition["configurations"]]
        labels = [item["variant_id"] for item in definition["configurations"]]
        cost_unit = definition["measurement_plan"][selected_cost]["unit"]
        time_unit = definition["measurement_plan"]["time"]["unit"]
        chart_files += draw_pareto_chart(
            plt,
            charts,
            "quality-cost-pareto",
            costs,
            qualities,
            labels,
            definition["configurations"],
            "Quality–cost performance curve",
            f"{selected_cost} ({cost_unit})",
            f"quality ({quality_unit})",
        )
        chart_files += draw_pareto_chart(
            plt,
            charts,
            "quality-time-pareto",
            elapsed,
            qualities,
            labels,
            definition["configurations"],
            "Quality–time performance curve",
            f"time ({time_unit})",
            f"quality ({quality_unit})",
        )
    reliability_axis = next(
        (
            axis
            for axis in comparison.get("axes", [])
            if axis.get("axis") == "reliability" and axis.get("case_count") == len(definition["cases"])
        ),
        None,
    )
    if state == "comparison-ready" and reliability_axis is not None:
        reliability_unit = definition["measurement_plan"]["reliability"]["unit"]
        chart_files += draw_reliability_chart(plt, charts, reliability_axis, reliability_unit)

    title = html.escape(definition["definition_id"])
    if state == "pilot-complete":
        method = (
            f"Descriptive completeness pilot with {len(definition['cases'])} cases, "
            f"{len(definition['configurations'])} variants, and one observation per case and variant; "
            "it makes no quality, reliability, comparison, or inference conclusion. "
            "The public API price estimate is derived from frozen public token prices and is not a provider invoice or subscription charge; "
            "token counts remain in metrics.csv as audit evidence rather than a primary chart."
        )
        conclusion = "Not applicable"
        visualization = (
            "Discrete Grade and hard-gate outcomes use matrices; absolute case-level elapsed time and public API price estimates "
            "use zero-baseline grouped bars. Token counts are audit-only in metrics.csv."
        )
        if definition["experiment_purpose"] == "model-effort-comparison":
            visualization += (
                " Each model and reasoning-effort configuration has an empirical cost-coverage step line showing the share of registered "
                "cases Accepted within each observed public API price threshold; the steps do not imply interpolation or a comparison conclusion."
            )
    else:
        method = (
            f"Formal paired case-outer bootstrap with 10,000 resamples, "
            f"{len(definition['cases'])} independent cases, "
            f"{definition['replicate_count']} replicates aggregated by mean, seed {definition['seed']}, "
            f"and practical minimum difference {definition['primary_metric']['practical_minimum_difference']}."
        )
        conclusion = comparison["conclusion"]
        visualization = "Formal charts show the preregistered paired effect or the quality-cost and quality-time trade-offs; reliability intervals require formal repeated evidence."
    missing = "reported in structured aggregate form" if any(axis.get("missing_cases") for axis in public_comparison.get("axes", [])) else "none"
    exclusion_count = sum(len(axis.get("exclusions", [])) for axis in public_comparison.get("axes", []) if isinstance(axis, dict))
    gates = "descriptive run-level outcomes only; not a formal comparison gate" if state == "pilot-complete" else ("passed" if comparison.get("hard_gates_passed") else "failed")
    grade_status_counts = dict(sorted(Counter(grade.get("status", "unverified") for grade in record["grades"] if isinstance(grade, dict)).items()))
    grader = definition["grader"]
    grader_summary = f"{grader['kind']} {grader['version_or_digest']} (blind={grader['blind_state']}, calibration={grader['calibration']}, adjudication={grader['adjudication']}, producer={grader['producer']})"
    if state == "pilot-complete":
        evidence_summary = f"imports={len(record['imports'])}, run evidence={len(record['runs'])}, Grade evidence={len(record['grades'])}"
        re_evaluation = "create a new formal-comparison Definition before making comparative claims"
    else:
        coverage = public_comparison["evidence_coverage"]
        evidence_summary = f"imports={coverage['imported_source_count']}, run evidence={coverage['run_evidence_verified']}, Grade evidence={coverage['grade_evidence_verified']}, coverage={coverage['coverage_status_counts']}"
        re_evaluation = ", ".join(public_comparison["re_evaluation_triggers"])
    suite = definition["suite"]
    variants = ", ".join(
        f"{item['variant_id']} ({item['model']}/{item['reasoning_effort']}; components={'+'.join(item['component_digests'])})"
        for item in definition["configurations"]
    )
    axis_lines = "; ".join(
        f"{axis['axis']} ({axis['unit']}, {axis['aggregation']}): estimate={axis.get('estimate', 'missing')}, CI={axis.get('confidence_interval_95', 'missing')}, cases={axis['case_count']}, missing={len(axis['missing_cases'])}, exclusions={len(axis['exclusions'])}"
        for axis in public_comparison.get("axes", [])
    ) or "No formal axis estimates"
    report_text = f"Suite: {suite['id']} {suite['version']} at {suite['git_sha']} digest {suite['digest']}. Variants: {variants}.\n\nHypothesis: {definition['hypothesis']}\n\nMethod: {method} Grader: {grader_summary}.\n\nVisualization: {visualization}\n\nMetrics: {axis_lines}.\n\nEvidence coverage: {evidence_summary}. Grade statuses: {grade_status_counts}. Missing: {missing}. Exclusions: {exclusion_count}. Hard gates: {gates}. Limits: private inputs and raw evidence are excluded. Re-evaluate when: {re_evaluation}. Conclusion: {conclusion}."
    svg_fragments = "".join(read_svg_fragment(output / path) for path in chart_files if path.endswith(".svg"))
    (output / "report.html").write_text(f"<!doctype html><html><body><h1>{title}</h1><p>{html.escape(report_text)}</p>{svg_fragments}</body></html>", encoding="utf-8")
    chart_references = "\n".join(f"- [{path}]({path})" for path in chart_files if path.endswith(".svg"))
    (output / "report.md").write_text(f"# {definition['definition_id']}\n\n{report_text}\n\nCharts:\n{chart_references}\n", encoding="utf-8")
    (output / "thread-summary.md").write_text(f"# {definition['definition_id']}\n\n{report_text}\n", encoding="utf-8")
    write_json(output / "comparison.json", public_comparison)
    artifacts = ["report.html", "report.md", "metrics.csv", *chart_files, "comparison.json", "report_manifest.json", "thread-summary.md"]
    hashes = {name: sha256((output / name).read_bytes()) for name in artifacts if name != "report_manifest.json"}
    price_basis = {
        "kind": "public-api-text-token-price-estimate",
        "catalog_digests": sorted({
            run["price_version_or_digest"]
            for run in record["runs"]
            if isinstance(run.get("derived_cost"), (int, float))
            and is_sha256(run.get("price_version_or_digest"))
        }),
        "observed_dates": sorted_effective_dates if state == "pilot-complete" else [],
        "interpretation": "Derived comparison basis; not provider-billed cost or a subscription charge.",
    }
    write_json(output / "report_manifest.json", {
        "definition_id": definition["definition_id"],
        "report_id": comparison.get("comparison_id") if state == "comparison-ready" else sha256(canonical_json({"definition_id": definition["definition_id"], "record_digest": record["record_digest"], "use_kind": "completeness-pilot"})),
        "report_status": "pilot-complete" if state == "pilot-complete" else "complete",
        "record_digest": record["record_digest"],
        "artifacts": artifacts,
        "artifact_digests": hashes,
        "self_hash_rule": "report_manifest.json is listed but excluded from artifact_digests",
        "python": sys.version,
        "matplotlib": matplotlib.__version__,
        "numpy": numpy.__version__,
        "packages": installed_packages,
        "backend": matplotlib.get_backend(),
        "price_basis": price_basis,
        "render_config": {"formats": ["svg", "png"], "self_contained_html": True, "case_keys": "opaque", "svg_hashsalt": "agent-benchmarking-v1", "svg_fonttype": "none", "font_family": "DejaVu Sans", "dpi": 120, "metadata_date": None},
    })


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    specifications = {
        "validate-suite": (validate_suite_command, (("--suite", True), ("--output", True), ("--git-sha", False))),
        "materialize-case": (materialize_case_command, (("--suite", True), ("--case-key", True), ("--output", True), ("--manifest-output", True), ("--git-sha", False))),
        "init": (init_command, (("--definition", True), ("--output", True))),
        "import-codex": (import_codex_command, (("--record", True), ("--jsonl", True))),
        "validate": (validate_command, (("--record", True),)),
        "compare": (compare_command, (("--record", True), ("--reference-variant", True), ("--candidate-variant", True), ("--output", True))),
        "setup-report": (setup_report_command, (("--output", True),)),
        "report": (report_command, (("--record", True), ("--output", True), ("--comparison", False))),
    }
    for name, (function, options) in specifications.items():
        command = commands.add_parser(name)
        for option, required in options:
            command.add_argument(option, required=required)
        command.set_defaults(function=function)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = build_parser().parse_args(argv)
        arguments.function(arguments)
    except (ContractError, OSError, UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"contract error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
