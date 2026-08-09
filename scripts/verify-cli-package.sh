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
package_path="${package_dir}/MackySoft.SkillsPack.${expected_version}.nupkg"
if [[ ! -f "${package_path}" ]]; then
  echo "CLI package was not created: ${package_path}" >&2
  exit 1
fi

temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
tool_path="$(mktemp -d "${temp_root%/}/skills-pack-tool.XXXXXX")"
trap 'rm -rf "${tool_path}"' EXIT

dotnet tool install \
  --tool-path "${tool_path}" \
  --add-source "${package_dir}" \
  MackySoft.SkillsPack \
  --version "${expected_version}"

actual_version="$("${tool_path}/skills-pack" --version)"
if [[ "${actual_version}" != "${expected_version}" ]]; then
  echo "Unexpected skills-pack --version. Expected: ${expected_version}. Actual: ${actual_version}" >&2
  exit 1
fi

package_entries="$(unzip -Z1 "${package_path}")"
for entry in README.md LICENSE tools/net10.0/any/DotnetToolSettings.xml; do
  if ! grep -Fx "${entry}" <<< "${package_entries}" >/dev/null; then
    echo "CLI package is missing required entry: ${entry}" >&2
    exit 1
  fi
done

generated_skills_root="${repo_root}/skills/generated"
while IFS= read -r skill_file; do
  relative_path="${skill_file#"${generated_skills_root}/"}"
  entry="tools/net10.0/any/skills/${relative_path}"
  if ! grep -Fx "${entry}" <<< "${package_entries}" >/dev/null; then
    echo "CLI package is missing required generated SKILL entry: ${entry}" >&2
    exit 1
  fi
done < <(find "${generated_skills_root}" -type f | sort)

bundle_entry="tools/net10.0/any/skills/bundle.json"
expected_bundle_path="${generated_skills_root}/bundle.json"
PACKAGE_PATH="${package_path}" BUNDLE_ENTRY="${bundle_entry}" EXPECTED_BUNDLE_PATH="${expected_bundle_path}" python3 - <<'PY'
import json
import os
import sys
import zipfile

with zipfile.ZipFile(os.environ["PACKAGE_PATH"]) as package:
    bundle = json.loads(package.read(os.environ["BUNDLE_ENTRY"]))

with open(os.environ["EXPECTED_BUNDLE_PATH"], encoding="utf-8") as descriptor:
    expected = json.load(descriptor)

if bundle != expected:
    print(
        f"CLI package bundle descriptor does not match the repository generated descriptor. Expected: {expected}. Actual: {bundle}",
        file=sys.stderr,
    )
    sys.exit(1)
PY

skills_list="$("${tool_path}/skills-pack" skills list)"
if ! grep -F '"command":"skills.list"' <<< "${skills_list}" >/dev/null; then
  echo "skills-pack skills list did not report the skills.list command." >&2
  exit 1
fi

SKILLS_LIST_JSON="${skills_list}" python3 - <<'PY'
import json
import os
import sys

result = json.loads(os.environ["SKILLS_LIST_JSON"])
skills = {
    skill["skillName"]: skill
    for skill in result["payload"]["skills"]
}

expected = {
    "change-framing": ("basic", {"claim-grounding", "referent-modeling"}),
    "test-oracle-assessment": ("development", {"claim-grounding", "referent-modeling"}),
    "code-authoring-rules": ("development", {"change-framing"}),
    "test-authoring": ("development", {"change-framing", "code-authoring-rules", "test-oracle-assessment"}),
    "verification-gate": ("development", {"test-oracle-assessment"}),
    "ultra-review": ("development", {"change-framing"}),
}

for skill_name, (expected_category, required_dependencies) in expected.items():
    skill = skills.get(skill_name)
    if skill is None:
        print(f"skills.list is missing required skill: {skill_name}", file=sys.stderr)
        sys.exit(1)

    if skill["category"] != expected_category:
        print(
            f"skills.list reported an unexpected category for {skill_name}. "
            f"Expected: {expected_category}. Actual: {skill['category']}",
            file=sys.stderr,
        )
        sys.exit(1)

    missing_dependencies = required_dependencies.difference(skill["dependencies"])
    if missing_dependencies:
        print(
            f"skills.list is missing required dependencies for {skill_name}: "
            f"{sorted(missing_dependencies)}",
            file=sys.stderr,
        )
        sys.exit(1)

forbidden_dependencies = {
    "ultra-review": {"test-oracle-assessment"},
}

for skill_name, forbidden in forbidden_dependencies.items():
    present = forbidden.intersection(skills[skill_name]["dependencies"])
    if present:
        print(
            f"skills.list reported forbidden direct dependencies for {skill_name}: "
            f"{sorted(present)}",
            file=sys.stderr,
        )
        sys.exit(1)
PY

export_root="${tool_path}/export-smoke"
export_result="$(
  "${tool_path}/skills-pack" skills export \
    --host openai \
    --skill test-authoring \
    --output "${export_root}"
)"

install_repo="${tool_path}/install-smoke"
mkdir -p "${install_repo}"
install_result="$(
  "${tool_path}/skills-pack" skills install \
    --host openai \
    --scope project \
    --repo-root "${install_repo}" \
    --skill ultra-review
)"

EXPORT_RESULT_JSON="${export_result}" \
INSTALL_RESULT_JSON="${install_result}" \
EXPORT_ROOT="${export_root}" \
INSTALL_REPO="${install_repo}" \
python3 - <<'PY'
import json
import os
from pathlib import Path
import sys

export_result = json.loads(os.environ["EXPORT_RESULT_JSON"])
install_result = json.loads(os.environ["INSTALL_RESULT_JSON"])

expected_export = {
    "change-framing",
    "claim-grounding",
    "code-authoring-rules",
    "referent-modeling",
    "test-authoring",
    "test-oracle-assessment",
    "writing",
}
actual_export = set(export_result["payload"]["skills"])
if actual_export != expected_export:
    print(
        "test-authoring export returned an unexpected dependency closure. "
        f"Expected: {sorted(expected_export)}. Actual: {sorted(actual_export)}",
        file=sys.stderr,
    )
    sys.exit(1)

export_root = Path(os.environ["EXPORT_ROOT"])
missing_export_files = [
    skill_name
    for skill_name in expected_export
    if not (export_root / skill_name / "SKILL.md").is_file()
]
if missing_export_files:
    print(
        f"test-authoring export is missing SKILL.md files: {sorted(missing_export_files)}",
        file=sys.stderr,
    )
    sys.exit(1)

expected_install = {
    "change-framing",
    "claim-grounding",
    "referent-modeling",
    "review-triage",
    "test-oracle-assessment",
    "ultra-review",
    "verification-gate",
    "writing",
}
actual_install = {
    action["skillName"]
    for action in install_result["payload"]["actions"]
}
if actual_install != expected_install:
    print(
        "ultra-review install returned an unexpected dependency closure. "
        f"Expected: {sorted(expected_install)}. Actual: {sorted(actual_install)}",
        file=sys.stderr,
    )
    sys.exit(1)

install_root = (
    Path(os.environ["INSTALL_REPO"])
    / ".agents"
    / "skills"
    / "com.mackysoft.skills-pack"
)
missing_install_files = [
    skill_name
    for skill_name in expected_install
    if not (install_root / skill_name / "SKILL.md").is_file()
]
if missing_install_files:
    print(
        f"ultra-review install is missing SKILL.md files: {sorted(missing_install_files)}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
