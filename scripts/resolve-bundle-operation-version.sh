#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: bash scripts/resolve-bundle-operation-version.sh --operation <verify|release|verify-release> --root <bundle-root> --base-ref <published-release-ref>" >&2
}

operation=""
bundle_root=""
base_ref=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --operation)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      operation="$2"
      shift 2
      ;;
    --root)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      bundle_root="$2"
      shift 2
      ;;
    --base-ref)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      base_ref="$2"
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

if [[ "${operation}" != "verify" && "${operation}" != "release" && "${operation}" != "verify-release" ]]; then
  usage
  exit 2
fi

if [[ -z "${bundle_root}" || -z "${base_ref}" ]]; then
  usage
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to resolve the bundle version." >&2
  exit 1
fi

repository_root="$(git rev-parse --show-toplevel)"
repository_root="$(cd -- "${repository_root}" && pwd -P)"
if ! resolved_bundle_root="$(cd -- "${bundle_root}" && pwd -P)"; then
  echo "The bundle root does not exist: ${bundle_root}" >&2
  exit 1
fi

case "${resolved_bundle_root}" in
  "${repository_root}")
    bundle_path="bundle.json"
    ;;
  "${repository_root}"/*)
    bundle_path="${resolved_bundle_root#"${repository_root}"/}/bundle.json"
    ;;
  *)
    echo "The bundle root must remain inside the Git worktree: ${bundle_root}" >&2
    exit 1
    ;;
esac

if ! base_commit="$(git rev-parse --verify --end-of-options "${base_ref}^{commit}")"; then
  echo "The published release ref does not resolve to a commit: ${base_ref}" >&2
  exit 1
fi

if ! base_bundle="$(git show "${base_commit}:${bundle_path}" 2>/dev/null)"; then
  echo "The published release ref does not contain ${bundle_path}: ${base_ref}" >&2
  exit 1
fi

read_catalog_id() {
  local description="$1"
  jq -er --arg description "${description}" '
    if (.catalogId | type) == "string" and (.catalogId | length) > 0
    then .catalogId
    else error($description + " must contain a non-empty catalogId")
    end
  '
}

read_bundle_version() {
  local description="$1"
  jq -er --arg description "${description}" '
    .bundleVersion as $version
    | if ($version | type) == "number"
        and ($version | floor) == $version
        and $version > 0
        and $version <= 2147483647
      then $version
      else error($description + " must contain a positive 32-bit integer bundleVersion")
      end
  '
}

base_catalog_id="$(read_catalog_id "Published bundle" <<< "${base_bundle}")"
current_catalog_id="$(read_catalog_id "Current bundle" < "${resolved_bundle_root}/bundle.json")"
if [[ "${current_catalog_id}" != "${base_catalog_id}" ]]; then
  echo "Current catalogId ${current_catalog_id} does not match published catalogId ${base_catalog_id}." >&2
  exit 1
fi

base_version="$(read_bundle_version "Published bundle" <<< "${base_bundle}")"
current_version="$(read_bundle_version "Current bundle" < "${resolved_bundle_root}/bundle.json")"

if [[ "${operation}" == "verify" ]]; then
  if [[ "${current_version}" -ne "${base_version}" ]]; then
    echo "Ordinary work must preserve the latest published bundle version ${base_version}; current version is ${current_version}." >&2
    exit 1
  fi

  printf '%s\n' "${base_version}"
  exit 0
fi

if [[ "${base_version}" -eq 2147483647 ]]; then
  echo "The published bundle version cannot be incremented beyond 2147483647." >&2
  exit 1
fi

target_version="$((base_version + 1))"
if [[ "${operation}" == "verify-release" ]]; then
  if [[ "${current_version}" -ne "${target_version}" ]]; then
    echo "Release work must use the next published bundle version ${target_version}; current version is ${current_version}." >&2
    exit 1
  fi

  printf '%s\n' "${target_version}"
  exit 0
fi

if [[ "${current_version}" -ne "${base_version}" && "${current_version}" -ne "${target_version}" ]]; then
  echo "Current bundle version ${current_version} must equal the published version ${base_version} or release target ${target_version}." >&2
  exit 1
fi

printf '%s\n' "${target_version}"
