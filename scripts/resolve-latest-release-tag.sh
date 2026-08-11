#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: bash scripts/resolve-latest-release-tag.sh --repository <owner/repository> [--remote <remote>]" >&2
}

repository=""
remote_name="origin"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repository)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      repository="$2"
      shift 2
      ;;
    --remote)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      remote_name="$2"
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

if [[ -z "${repository}" || -z "${remote_name}" ]]; then
  usage
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to resolve the latest published release." >&2
  exit 1
fi

release_tag="$(gh release view --repo "${repository}" --json tagName --jq .tagName)"
if [[ ! "${release_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "The latest published release tag must use <major>.<minor>.<patch>. Actual: ${release_tag}" >&2
  exit 1
fi

if ! git ls-remote --exit-code --tags "${remote_name}" "refs/tags/${release_tag}" >/dev/null; then
  echo "The latest published release tag does not exist on ${remote_name}: ${release_tag}" >&2
  exit 1
fi

git fetch --force --no-tags "${remote_name}" "refs/tags/${release_tag}:refs/tags/${release_tag}" >/dev/null
printf '%s\n' "${release_tag}"
