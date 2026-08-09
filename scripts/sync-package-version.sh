#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/sync-package-version.sh --version <version>

Updates repository files that track the unified AgentBundle package version.
EOF
}

package_version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      package_version="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${package_version}" ]]; then
  usage
  exit 2
fi

if [[ ! "${package_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Package version must use <major>.<minor>.<patch>. Actual: ${package_version}" >&2
  exit 1
fi

python3 - "$package_version" <<'PY'
import pathlib
import re
import sys

version = sys.argv[1]
path = pathlib.Path("Directory.Build.props")
text = path.read_text(encoding="utf-8")
updated = re.sub(r"<Version>[^<]+</Version>", f"<Version>{version}</Version>", text, count=1)
if updated == text:
    print("Directory.Build.props does not contain a Version element.", file=sys.stderr)
    sys.exit(1)
path.write_text(updated, encoding="utf-8")
PY
