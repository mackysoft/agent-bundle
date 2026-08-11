#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/merge-release-pull-request.sh \
  --repository <owner/name> \
  --default-branch <branch> \
  --release-branch <release/version> \
  --expected-sha <commit>

Creates or reuses the release pull request, dispatches verification for its exact
head commit, waits for that run, and merges the verified commit.
EOF
}

repository=""
default_branch=""
release_branch=""
expected_sha=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      repository="$2"
      shift 2
      ;;
    --default-branch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      default_branch="$2"
      shift 2
      ;;
    --release-branch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      release_branch="$2"
      shift 2
      ;;
    --expected-sha)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      expected_sha="$2"
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

if [[ -z "${repository}" || -z "${default_branch}" || -z "${release_branch}" || -z "${expected_sha}" ]]; then
  usage
  exit 2
fi

if [[ ! "${repository}" =~ ^[^/]+/[^/]+$ ]]; then
  echo "Repository must use owner/name format: ${repository}" >&2
  exit 1
fi

if [[ ! "${release_branch}" =~ ^release/[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release branch must use release/<major>.<minor>.<patch> format: ${release_branch}" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "gh and jq are required to verify and merge the release pull request." >&2
  exit 1
fi

resolved_expected_sha="$(git rev-parse --verify --end-of-options "${expected_sha}^{commit}")"
current_sha="$(git rev-parse HEAD)"
if [[ "${current_sha}" != "${resolved_expected_sha}" ]]; then
  echo "Current commit ${current_sha} does not match expected release commit ${resolved_expected_sha}." >&2
  exit 1
fi

remote_head="$(git ls-remote --heads origin "refs/heads/${release_branch}")"
remote_head_sha="${remote_head%%[[:space:]]*}"
if [[ -z "${remote_head_sha}" || "${remote_head_sha}" != "${resolved_expected_sha}" ]]; then
  echo "Remote release branch ${release_branch} must point to ${resolved_expected_sha}; actual: ${remote_head_sha:-<missing>}." >&2
  exit 1
fi

pull_requests="$(gh pr list \
  --repo "${repository}" \
  --state open \
  --base "${default_branch}" \
  --head "${release_branch}" \
  --json number,headRefOid)"
pull_request_count="$(jq 'length' <<< "${pull_requests}")"

if [[ "${pull_request_count}" -eq 0 ]]; then
  release_version="${release_branch#release/}"
  pull_request_url="$(gh pr create \
    --repo "${repository}" \
    --base "${default_branch}" \
    --head "${release_branch}" \
    --title "chore(release): prepare ${release_version}" \
    --body "Release-owned bundle version increment and generated output for ${release_version}.")"
  pull_request_number="$(gh pr view "${pull_request_url}" --repo "${repository}" --json number --jq '.number')"
elif [[ "${pull_request_count}" -eq 1 ]]; then
  pull_request_number="$(jq -r '.[0].number' <<< "${pull_requests}")"
  pull_request_head="$(jq -r '.[0].headRefOid' <<< "${pull_requests}")"
  if [[ "${pull_request_head}" != "${resolved_expected_sha}" ]]; then
    echo "Release pull request #${pull_request_number} points to ${pull_request_head}, expected ${resolved_expected_sha}." >&2
    exit 1
  fi
else
  echo "More than one open release pull request targets ${default_branch} from ${release_branch}." >&2
  exit 1
fi

previous_run_id="$(gh run list \
  --repo "${repository}" \
  --workflow verify.yaml \
  --branch "${release_branch}" \
  --commit "${resolved_expected_sha}" \
  --event workflow_dispatch \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId // 0')"

gh workflow run verify.yaml \
  --repo "${repository}" \
  --ref "${release_branch}" \
  --field expected_sha="${resolved_expected_sha}" \
  --field bundle_operation=verify-release

verification_run_id=""
for _ in {1..60}; do
  verification_run_id="$(gh run list \
    --repo "${repository}" \
    --workflow verify.yaml \
    --branch "${release_branch}" \
    --commit "${resolved_expected_sha}" \
    --event workflow_dispatch \
    --limit 10 \
    --json databaseId \
    --jq "[.[] | select(.databaseId > ${previous_run_id})][0].databaseId // empty")"
  if [[ -n "${verification_run_id}" ]]; then
    break
  fi

  sleep 2
done

if [[ -z "${verification_run_id}" ]]; then
  echo "Timed out waiting for the dispatched verification run for ${resolved_expected_sha}." >&2
  exit 1
fi

gh run watch "${verification_run_id}" --repo "${repository}" --exit-status

verified_head="$(gh pr view "${pull_request_number}" --repo "${repository}" --json headRefOid --jq '.headRefOid')"
if [[ "${verified_head}" != "${resolved_expected_sha}" ]]; then
  echo "Release pull request #${pull_request_number} changed from verified commit ${resolved_expected_sha} to ${verified_head}." >&2
  exit 1
fi

gh pr merge "${pull_request_number}" \
  --repo "${repository}" \
  --merge \
  --delete-branch \
  --match-head-commit "${resolved_expected_sha}"

pull_request_state="$(gh pr view "${pull_request_number}" --repo "${repository}" --json state,mergeCommit)"
if [[ "$(jq -r '.state' <<< "${pull_request_state}")" != "MERGED" ]]; then
  echo "Release pull request #${pull_request_number} was not merged." >&2
  exit 1
fi

merge_sha="$(jq -er '.mergeCommit.oid' <<< "${pull_request_state}")"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "merge_sha=${merge_sha}" >> "${GITHUB_OUTPUT}"
else
  echo "${merge_sha}"
fi
