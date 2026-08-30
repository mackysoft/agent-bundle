#!/usr/bin/env bash
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python_bin="${PYTHON:-python3}"

if "$python_bin" -c 'import sys; raise SystemExit(sys.version_info[:2] != (3, 12))'; then
  environment_root="$(mktemp -d)"
  trap 'rm -rf "$environment_root"' EXIT
  "$python_bin" "${script_dir}/../bundle/skills/agent-harness/agent-benchmarking/scripts/benchmark.py" setup-report --output "$environment_root"
  report_python="${environment_root}/.report-venv/bin/python"
  BENCHMARK_REPORT_ENVIRONMENT=1 "$report_python" "${script_dir}/../tests/agent-benchmarking/test_benchmark.py"
else
  "$python_bin" "${script_dir}/../tests/agent-benchmarking/test_benchmark.py"
fi
