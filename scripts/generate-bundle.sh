#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/dotnet-common.sh
source "$script_dir/dotnet-common.sh"

if [[ "$#" -ne 0 ]]; then
  echo "usage: bash scripts/generate-bundle.sh" >&2
  exit 2
fi

cd "$DOTNET_REPO_ROOT"
dotnet tool restore >/dev/null
dotnet tool run agent-distribution -- build --root bundle
