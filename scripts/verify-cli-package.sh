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

generated_bundle_root="${repo_root}/artifacts/agent-distribution"
if [[ ! -d "${generated_bundle_root}" ]]; then
  echo "Generated Agent Distribution bundle does not exist: ${generated_bundle_root}" >&2
  exit 1
fi
package_bundle_root="tools/net10.0/any/agent-distribution"
PACKAGE_PATH="${package_path}" REPO_ROOT="${repo_root}" GENERATED_BUNDLE_ROOT="${generated_bundle_root}" PACKAGE_BUNDLE_ROOT="${package_bundle_root}" python3 - <<'PY'
import os
from pathlib import Path
import sys
import zipfile

repo_root = Path(os.environ["REPO_ROOT"])
generated_root = Path(os.environ["GENERATED_BUNDLE_ROOT"])
package_bundle_root = os.environ["PACKAGE_BUNDLE_ROOT"]
expected_files = {
    "README.md": repo_root / "README.md",
    "LICENSE": repo_root / "LICENSE",
}
expected_files.update(
    {
        f"{package_bundle_root}/{path.relative_to(generated_root).as_posix()}": path
        for path in generated_root.rglob("*")
        if path.is_file()
    }
)

with zipfile.ZipFile(os.environ["PACKAGE_PATH"]) as package:
    for entry, source in expected_files.items():
        try:
            actual = package.read(entry)
        except KeyError:
            print(f"CLI package is missing required entry: {entry}", file=sys.stderr)
            sys.exit(1)
        expected = source.read_bytes()
        if actual != expected:
            print(f"CLI package entry differs from its repository source: {entry}", file=sys.stderr)
            sys.exit(1)
PY

"${tool_path}/agent-bundle" skills list >/dev/null
"${tool_path}/agent-bundle" agents list >/dev/null
