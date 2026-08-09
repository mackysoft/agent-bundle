#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <package-dir> <expected-version>" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
package_dir="$1"
expected_version="$2"

if [[ ! -d "${package_dir}" ]]; then
  echo "CLI package directory does not exist: ${package_dir}" >&2
  exit 1
fi

package_dir="$(cd "${package_dir}" && pwd)"
package_path="${package_dir}/MackySoft.AgentBundle.${expected_version}.nupkg"
if [[ ! -f "${package_path}" ]]; then
  echo "CLI package was not created: ${package_path}" >&2
  exit 1
fi

temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
tool_path="$(mktemp -d "${temp_root%/}/agent-bundle-tool.XXXXXX")"
trap 'rm -rf "${tool_path}"' EXIT

dotnet tool install \
  --tool-path "${tool_path}" \
  --source "${package_dir}" \
  MackySoft.AgentBundle \
  --version "${expected_version}"

actual_version="$("${tool_path}/agent-bundle" --version)"
if [[ "${actual_version}" != "${expected_version}" ]]; then
  echo "Unexpected agent-bundle --version. Expected: ${expected_version}. Actual: ${actual_version}" >&2
  exit 1
fi

package_entries="$(unzip -Z1 "${package_path}")"
for entry in README.md LICENSE tools/net10.0/any/DotnetToolSettings.xml; do
  if ! grep -Fx "${entry}" <<< "${package_entries}" >/dev/null; then
    echo "CLI package is missing required entry: ${entry}" >&2
    exit 1
  fi
done

generated_bundle_root="${repo_root}/bundle/generated"
package_bundle_root="tools/net10.0/any/skills"
while IFS= read -r bundle_file; do
  relative_path="${bundle_file#"${generated_bundle_root}/"}"
  entry="${package_bundle_root}/${relative_path}"
  if ! grep -Fx "${entry}" <<< "${package_entries}" >/dev/null; then
    echo "CLI package is missing required generated bundle entry: ${entry}" >&2
    exit 1
  fi
done < <(find "${generated_bundle_root}" -type f | sort)

bundle_entry="${package_bundle_root}/bundle.json"
expected_bundle_path="${generated_bundle_root}/bundle.json"
PACKAGE_PATH="${package_path}" BUNDLE_ENTRY="${bundle_entry}" EXPECTED_BUNDLE_PATH="${expected_bundle_path}" python3 - <<'PY'
import json
import os
import sys
import zipfile
import xml.etree.ElementTree as ET

with zipfile.ZipFile(os.environ["PACKAGE_PATH"]) as package:
    bundle = json.loads(package.read(os.environ["BUNDLE_ENTRY"]))
    tool_settings = ET.fromstring(
        package.read("tools/net10.0/any/DotnetToolSettings.xml").decode("utf-8-sig")
    )

with open(os.environ["EXPECTED_BUNDLE_PATH"], encoding="utf-8") as descriptor:
    expected = json.load(descriptor)

if bundle != expected:
    print(
        f"CLI package bundle descriptor does not match the repository generated descriptor. Expected: {expected}. Actual: {bundle}",
        file=sys.stderr,
    )
    sys.exit(1)

commands = [
    {
        "Name": command.get("Name"),
        "EntryPoint": command.get("EntryPoint"),
        "Runner": command.get("Runner"),
    }
    for command in tool_settings.findall("./Commands/Command")
]
expected_commands = [
    {
        "Name": "agent-bundle",
        "EntryPoint": "MackySoft.AgentBundle.dll",
        "Runner": "dotnet",
    }
]
if commands != expected_commands:
    print(
        f"Unexpected .NET tool command contract. Expected: {expected_commands}. Actual: {commands}",
        file=sys.stderr,
    )
    sys.exit(1)
PY

skills_list="$("${tool_path}/agent-bundle" skills list)"
agents_list="$("${tool_path}/agent-bundle" agents list)"
SKILLS_LIST="${skills_list}" AGENTS_LIST="${agents_list}" python3 - <<'PY'
import json
import os
import sys

skills = json.loads(os.environ["SKILLS_LIST"])
agents = json.loads(os.environ["AGENTS_LIST"])


def require_equal(label, expected, actual):
    if actual != expected:
        print(f"Unexpected {label}. Expected: {expected}. Actual: {actual}", file=sys.stderr)
        sys.exit(1)


expected_agent_hosts = {"codex", "claude-code", "github-copilot"}

require_equal("skills list product", "AgentBundle", skills.get("Product"))
require_equal("skills list command", "skills.list", skills.get("Command"))
require_equal("skills list status", "ok", skills.get("Status"))
skills_payload = skills.get("Payload") or {}
if "writing" not in {item["SkillName"] for item in skills_payload.get("Skills", [])}:
    print("skills list did not report the writing Skill used by the export smoke test.", file=sys.stderr)
    sys.exit(1)

require_equal("agents list product", "AgentBundle", agents.get("Product"))
require_equal("agents list command", "agents.list", agents.get("Command"))
require_equal("agents list status", "ok", agents.get("Status"))
agents_payload = agents.get("Payload") or {}
if "reviewer" not in {item["AgentName"] for item in agents_payload.get("Agents", [])}:
    print("agents list did not report the reviewer used by the export smoke test.", file=sys.stderr)
    sys.exit(1)
require_equal(
    "supported custom-agent hosts",
    expected_agent_hosts,
    set(agents_payload.get("SupportedHostIds", [])),
)
PY

consumer_root="$(mktemp -d "${temp_root%/}/agent-bundle-consumer.XXXXXX")"
trap 'rm -rf "${tool_path}" "${consumer_root}"' EXIT

resolve_skill_closure() {
  local selection_kind="$1"
  local selection_name="$2"

  PACKAGE_PATH="${package_path}" \
    PACKAGE_BUNDLE_ROOT="${package_bundle_root}" \
    SELECTION_KIND="${selection_kind}" \
    SELECTION_NAME="${selection_name}" \
    python3 - <<'PY'
import json
import os
import zipfile

bundle_root = os.environ["PACKAGE_BUNDLE_ROOT"]
selection_kind = os.environ["SELECTION_KIND"]
selection_name = os.environ["SELECTION_NAME"]

with zipfile.ZipFile(os.environ["PACKAGE_PATH"]) as package:
    if selection_kind == "agent":
        agent_path = f"{bundle_root}/agents/{selection_name}/agent-manifest.json"
        pending = json.loads(package.read(agent_path)).get("skillDependencies") or []
    elif selection_kind == "skill":
        pending = [selection_name]
    else:
        raise ValueError(f"Unsupported selection kind: {selection_kind}")

    resolved = set()
    while pending:
        skill_name = pending.pop()
        if skill_name in resolved:
            continue
        skill_path = f"{bundle_root}/skills/{skill_name}/agent-skill.json"
        skill = json.loads(package.read(skill_path))
        resolved.add(skill_name)
        pending.extend(skill.get("dependencies") or [])

print(json.dumps(sorted(resolved), separators=(",", ":")))
PY
}

verify_doctor_report() {
  local report="$1"
  local expected_command="$2"

  REPORT="${report}" EXPECTED_COMMAND="${expected_command}" python3 - <<'PY'
import json
import os
import sys

report = json.loads(os.environ["REPORT"])
expected_command = os.environ["EXPECTED_COMMAND"]
payload = report.get("Payload") or {}

checks = {
    "command": (expected_command, report.get("Command")),
    "status": ("ok", report.get("Status")),
    "health": (True, payload.get("IsHealthy")),
}
if expected_command == "agents.doctor":
    checks["Skill health"] = (True, (payload.get("SkillReport") or {}).get("IsHealthy"))

for label, (expected, actual) in checks.items():
    if actual != expected:
        print(
            f"Unexpected {expected_command} {label}. Expected: {expected}. Actual: {actual}",
            file=sys.stderr,
        )
        sys.exit(1)
PY
}

verify_agent_install_report() {
  local report="$1"
  local expected_agent="$2"
  local expected_artifact_root="$3"
  local expected_state_root="$4"
  local expected_skill_root="$5"
  local agent_extension="$6"
  local expected_skills="$7"

  REPORT="${report}" \
    EXPECTED_AGENT="${expected_agent}" \
    EXPECTED_ARTIFACT_ROOT="${expected_artifact_root}" \
    EXPECTED_STATE_ROOT="${expected_state_root}" \
    EXPECTED_SKILL_ROOT="${expected_skill_root}" \
    AGENT_EXTENSION="${agent_extension}" \
    EXPECTED_SKILLS="${expected_skills}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path
import sys

report = json.loads(os.environ["REPORT"])
payload = report.get("Payload") or {}
skill_report = payload.get("SkillReport") or {}


def require_equal(label, expected, actual):
    if actual != expected:
        print(f"Unexpected {label}. Expected: {expected}. Actual: {actual}", file=sys.stderr)
        sys.exit(1)


require_equal("agents install command", "agents.install", report.get("Command"))
require_equal("agents install status", "ok", report.get("Status"))
require_equal(
    "agents install artifact root",
    os.environ["EXPECTED_ARTIFACT_ROOT"],
    payload.get("ArtifactRoot"),
)
require_equal(
    "agents install state root",
    os.environ["EXPECTED_STATE_ROOT"],
    payload.get("StateRoot"),
)
require_equal(
    "agents install Skill target root",
    os.environ["EXPECTED_SKILL_ROOT"],
    skill_report.get("TargetRoot"),
)

agent_names = payload.get("AgentNames") or []
if os.environ["EXPECTED_AGENT"] not in agent_names:
    print(
        f"agents install did not report the requested Agent: {os.environ['EXPECTED_AGENT']}",
        file=sys.stderr,
    )
    sys.exit(1)

expected_skills = set(json.loads(os.environ["EXPECTED_SKILLS"]))
reported_skills = {
    action.get("SkillName")
    for action in skill_report.get("Actions") or []
}
require_equal(
    "agents install resolved Skill set",
    sorted(expected_skills),
    sorted(reported_skills),
)

artifact_root = Path(payload["ArtifactRoot"])
state_root = Path(payload["StateRoot"]) / "com.mackysoft.agent-bundle"
skill_root = Path(skill_report["TargetRoot"])
required_files = [
    artifact_root / f"{agent_name}{os.environ['AGENT_EXTENSION']}"
    for agent_name in agent_names
]
required_files.extend(state_root / f"{agent_name}.json" for agent_name in agent_names)
required_files.extend(
    path
    for skill_name in reported_skills
    for path in (
        skill_root / skill_name / "SKILL.md",
        skill_root / skill_name / "agent-skill.json",
    )
)

missing_files = [str(path) for path in required_files if not path.is_file()]
if missing_files:
    print(
        "agents install did not create the artifacts declared by its report: "
        + ", ".join(missing_files),
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

reviewer_skill_closure="$(resolve_skill_closure agent reviewer)"
architect_skill_closure="$(resolve_skill_closure agent architect)"
implementer_skill_closure="$(resolve_skill_closure agent implementer)"
writing_skill_closure="$(resolve_skill_closure skill writing)"
branch_create_skill_closure="$(resolve_skill_closure skill branch-create)"

for legacy_host in openai claude copilot; do
  if "${tool_path}/agent-bundle" skills export \
    --host "${legacy_host}" \
    --skill writing \
    --output "${consumer_root}/legacy-host-${legacy_host}" >/dev/null 2>&1; then
    echo "agent-bundle accepted the removed host literal: ${legacy_host}" >&2
    exit 1
  fi
done

skill_export_target="${consumer_root}/skill-export"
skill_export_report="$("${tool_path}/agent-bundle" skills export \
  --host codex \
  --skill writing \
  --output "${skill_export_target}")"
SKILL_EXPORT_REPORT="${skill_export_report}" \
  EXPECTED_OUTPUT_PATH="${skill_export_target}" \
  EXPECTED_SKILLS="${writing_skill_closure}" \
  python3 - <<'PY'
import json
import os
from pathlib import Path
import sys

report = json.loads(os.environ["SKILL_EXPORT_REPORT"])
payload = report.get("Payload") or {}


def require_equal(label, expected, actual):
    if actual != expected:
        print(f"Unexpected {label}. Expected: {expected}. Actual: {actual}", file=sys.stderr)
        sys.exit(1)


require_equal("skills export command", "skills.export", report.get("Command"))
require_equal("skills export status", "ok", report.get("Status"))
require_equal(
    "skills export output path",
    os.environ["EXPECTED_OUTPUT_PATH"],
    payload.get("OutputPath"),
)
if "writing" not in (payload.get("SkillNames") or []):
    print("skills export did not report the requested writing Skill.", file=sys.stderr)
    sys.exit(1)

expected_skills = set(json.loads(os.environ["EXPECTED_SKILLS"]))
reported_skills = set(payload.get("Skills") or [])
require_equal(
    "skills export resolved Skill set",
    sorted(expected_skills),
    sorted(reported_skills),
)

output_path = Path(payload["OutputPath"])
required_files = [
    path
    for skill_name in reported_skills
    for path in (
        output_path / skill_name / "SKILL.md",
        output_path / skill_name / "agent-skill.json",
    )
]
missing_files = [str(path) for path in required_files if not path.is_file()]
if missing_files:
    print(
        "skills export did not create the artifacts declared by its report: "
        + ", ".join(missing_files),
        file=sys.stderr,
    )
    sys.exit(1)
PY

agent_export_target="${consumer_root}/agent-export"
agent_export_report="$("${tool_path}/agent-bundle" agents export \
  --host codex \
  --agent reviewer \
  --output "${agent_export_target}")"
AGENT_EXPORT_REPORT="${agent_export_report}" \
  EXPECTED_OUTPUT_PATH="${agent_export_target}" \
  EXPECTED_SKILLS="${reviewer_skill_closure}" \
  python3 - <<'PY'
import json
import os
from pathlib import Path
import sys

report = json.loads(os.environ["AGENT_EXPORT_REPORT"])
payload = report.get("Payload") or {}


def require_equal(label, expected, actual):
    if actual != expected:
        print(f"Unexpected {label}. Expected: {expected}. Actual: {actual}", file=sys.stderr)
        sys.exit(1)


require_equal("agents export command", "agents.export", report.get("Command"))
require_equal("agents export status", "ok", report.get("Status"))
require_equal(
    "agents export output path",
    os.environ["EXPECTED_OUTPUT_PATH"],
    payload.get("OutputPath"),
)

agent_names = payload.get("Agents") or []
if "reviewer" not in agent_names:
    print("agents export did not report the requested reviewer Agent.", file=sys.stderr)
    sys.exit(1)

expected_skills = set(json.loads(os.environ["EXPECTED_SKILLS"]))
reported_skills = set(payload.get("Skills") or [])
require_equal(
    "agents export resolved Skill set",
    sorted(expected_skills),
    sorted(reported_skills),
)

output_path = Path(payload["OutputPath"])
required_files = [output_path / "agents" / f"{agent_name}.toml" for agent_name in agent_names]
required_files.extend(
    path
    for skill_name in reported_skills
    for path in (
        output_path / "skills" / skill_name / "SKILL.md",
        output_path / "skills" / skill_name / "agent-skill.json",
    )
)
missing_files = [str(path) for path in required_files if not path.is_file()]
if missing_files:
    print(
        "agents export did not create the artifacts declared by its report: "
        + ", ".join(missing_files),
        file=sys.stderr,
    )
    sys.exit(1)
PY

for host in codex claude-code github-copilot; do
  install_report="$("${tool_path}/agent-bundle" agents install \
    --host "${host}" \
    --scope project \
    --repository-root "${consumer_root}" \
    --agent architect)"

  case "${host}" in
    codex)
      agent_artifact_root="${consumer_root}/.codex/agents"
      agent_extension=".toml"
      skill_target="${consumer_root}/.agents/skills/com.mackysoft.agent-bundle"
      ownership_state_root="${consumer_root}/.codex/agent-distribution/agents"
      ;;
    claude-code)
      agent_artifact_root="${consumer_root}/.claude/agents"
      agent_extension=".md"
      skill_target="${consumer_root}/.claude/skills"
      ownership_state_root="${consumer_root}/.claude/agent-distribution/agents"
      ;;
    github-copilot)
      agent_artifact_root="${consumer_root}/.github/agents"
      agent_extension=".agent.md"
      skill_target="${consumer_root}/.github/skills/com.mackysoft.agent-bundle"
      ownership_state_root="${consumer_root}/.github/agent-distribution/agents"
      ;;
  esac

  verify_agent_install_report \
    "${install_report}" \
    "architect" \
    "${agent_artifact_root}" \
    "${ownership_state_root}" \
    "${skill_target}" \
    "${agent_extension}" \
    "${architect_skill_closure}"

  doctor_report="$("${tool_path}/agent-bundle" agents doctor \
    --host "${host}" \
    --scope project \
    --repository-root "${consumer_root}" \
    --agent architect)"
  verify_doctor_report "${doctor_report}" "agents.doctor"
done

skill_install_report="$("${tool_path}/agent-bundle" skills install \
  --host codex \
  --scope project \
  --repository-root "${consumer_root}" \
  --skill branch-create)"
SKILL_INSTALL_REPORT="${skill_install_report}" \
  EXPECTED_SKILL_ROOT="${consumer_root}/.agents/skills/com.mackysoft.agent-bundle" \
  EXPECTED_SKILLS="${branch_create_skill_closure}" \
  python3 - <<'PY'
import json
import os
from pathlib import Path
import sys

report = json.loads(os.environ["SKILL_INSTALL_REPORT"])
payload = report.get("Payload") or {}


def require_equal(label, expected, actual):
    if actual != expected:
        print(f"Unexpected {label}. Expected: {expected}. Actual: {actual}", file=sys.stderr)
        sys.exit(1)


require_equal("skills install command", "skills.install", report.get("Command"))
require_equal("skills install status", "ok", report.get("Status"))
require_equal(
    "skills install target root",
    os.environ["EXPECTED_SKILL_ROOT"],
    payload.get("TargetRoot"),
)

skill_names = payload.get("SkillNames") or []
if "branch-create" not in skill_names:
    print("skills install did not report the requested branch-create Skill.", file=sys.stderr)
    sys.exit(1)

expected_skills = set(json.loads(os.environ["EXPECTED_SKILLS"]))
reported_skills = {
    action.get("SkillName")
    for action in payload.get("Actions") or []
}
require_equal(
    "skills install resolved Skill set",
    sorted(expected_skills),
    sorted(reported_skills),
)

target_root = Path(payload["TargetRoot"])
required_files = [
    path
    for skill_name in reported_skills
    for path in (
        target_root / skill_name / "SKILL.md",
        target_root / skill_name / "agent-skill.json",
    )
]
missing_files = [str(path) for path in required_files if not path.is_file()]
if missing_files:
    print(
        "skills install did not create the artifacts declared by its report: "
        + ", ".join(missing_files),
        file=sys.stderr,
    )
    sys.exit(1)
PY
skill_doctor_report="$("${tool_path}/agent-bundle" skills doctor \
  --host codex \
  --scope project \
  --repository-root "${consumer_root}" \
  --skill branch-create)"
verify_doctor_report "${skill_doctor_report}" "skills.doctor"

implementer_agent_target="${consumer_root}/transitive-install/agents"
implementer_skill_target="${consumer_root}/transitive-install/skills"
implementer_install_report="$("${tool_path}/agent-bundle" agents install \
  --host codex \
  --scope project \
  --repository-root "${consumer_root}" \
  --agent implementer \
  --agent-target-dir "${implementer_agent_target}" \
  --skill-target-dir "${implementer_skill_target}")"
verify_agent_install_report \
  "${implementer_install_report}" \
  "implementer" \
  "${implementer_agent_target}" \
  "${consumer_root}/transitive-install/.agent-distribution/agents" \
  "${implementer_skill_target}" \
  ".toml" \
  "${implementer_skill_closure}"

implementer_doctor_report="$("${tool_path}/agent-bundle" agents doctor \
  --host codex \
  --scope project \
  --repository-root "${consumer_root}" \
  --agent implementer \
  --agent-target-dir "${implementer_agent_target}" \
  --skill-target-dir "${implementer_skill_target}")"
verify_doctor_report "${implementer_doctor_report}" "agents.doctor"
