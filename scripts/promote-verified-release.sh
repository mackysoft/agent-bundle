#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/promote-verified-release.sh \
  --mode <promote|verify-promoted> \
  --repository <owner/name> \
  --default-branch <branch> \
  --release-branch <release/version> \
  --expected-sha <commit> \
  --target-bundle-version <version> \
  --expected-author-name <name> \
  --expected-author-email <email>

promote requires the release branch's push verification before fast-forwarding
the default branch. verify-promoted reuses the default branch's push
verification without changing refs.
EOF
}

mode=""
repository=""
default_branch=""
release_branch=""
expected_sha=""
target_bundle_version=""
expected_author_name=""
expected_author_email=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      mode="$2"
      shift 2
      ;;
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
    --target-bundle-version)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      target_bundle_version="$2"
      shift 2
      ;;
    --expected-author-name)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      expected_author_name="$2"
      shift 2
      ;;
    --expected-author-email)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      expected_author_email="$2"
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

if [[ ( "${mode}" != "promote" && "${mode}" != "verify-promoted" ) \
  || -z "${repository}" \
  || -z "${default_branch}" \
  || -z "${release_branch}" \
  || -z "${expected_sha}" \
  || -z "${target_bundle_version}" \
  || -z "${expected_author_name}" \
  || -z "${expected_author_email}" ]]; then
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

if [[ ! "${target_bundle_version}" =~ ^[1-9][0-9]*$ || "${target_bundle_version}" -gt 2147483647 ]]; then
  echo "Target bundle version must be a positive 32-bit integer: ${target_bundle_version}" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "gh, git, and jq are required to verify a release candidate." >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is required to verify a release candidate." >&2
  exit 1
fi

if [[ "${mode}" == "promote" && -z "${RELEASE_BOT_TOKEN:-}" ]]; then
  echo "RELEASE_BOT_TOKEN is required to promote a release candidate." >&2
  exit 1
fi

ref_sha() {
  local ref_name="$1"
  gh api "repos/${repository}/git/ref/heads/${ref_name}" --jq '.object.sha'
}

latest_release() {
  local release
  local release_id
  local release_tag
  local release_target_sha

  release="$(gh release view --repo "${repository}" --json id,tagName)"
  release_id="$(jq -er '.id' <<< "${release}")"
  release_tag="$(jq -er '.tagName' <<< "${release}")"
  if [[ ! "${release_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "The latest published release tag must use <major>.<minor>.<patch>. Actual: ${release_tag}" >&2
    exit 1
  fi

  git fetch --force --no-tags origin "refs/tags/${release_tag}:refs/tags/${release_tag}" >/dev/null
  release_target_sha="$(git rev-parse --verify --end-of-options "refs/tags/${release_tag}^{commit}")"
  printf '%s\t%s\t%s\n' "${release_id}" "${release_tag}" "${release_target_sha}"
}

validate_candidate() {
  local candidate_sha="$1"
  local candidate_version
  local changed_path
  local has_bundle_version_update="false"
  local author_name
  local author_email
  local committer_name
  local committer_email

  candidate_parents=( $(git rev-list --parents -n 1 "${candidate_sha}") )
  if [[ "${#candidate_parents[@]}" -ne 2 || "${candidate_parents[0]}" != "${candidate_sha}" ]]; then
    echo "Release candidate ${candidate_sha} must have exactly one parent." >&2
    exit 1
  fi

  candidate_base_sha="${candidate_parents[1]}"
  candidate_version="$(git show "${candidate_sha}:bundle/bundle.json" | jq -er '.bundleVersion')"
  if [[ "${candidate_version}" != "${target_bundle_version}" ]]; then
    echo "Release candidate ${candidate_sha} must use bundle version ${target_bundle_version}; actual: ${candidate_version}." >&2
    exit 1
  fi

  read -r author_name author_email committer_name committer_email < <(git show -s --format='%an %ae %cn %ce' "${candidate_sha}")
  if [[ "${author_name}" != "${expected_author_name}" \
    || "${author_email}" != "${expected_author_email}" \
    || "${committer_name}" != "${expected_author_name}" \
    || "${committer_email}" != "${expected_author_email}" ]]; then
    echo "Release candidate ${candidate_sha} must be authored and committed by ${expected_author_name}." >&2
    exit 1
  fi

  while IFS= read -r changed_path; do
    if [[ "${changed_path}" == "bundle/bundle.json" ]]; then
      has_bundle_version_update="true"
      continue
    fi

    if [[ "${changed_path}" == bundle/generated/* ]]; then
      continue
    fi

    echo "Release candidate ${candidate_sha} changes an unsupported path: ${changed_path}" >&2
    exit 1
  done < <(git diff --name-only "${candidate_base_sha}" "${candidate_sha}")

  if [[ "${has_bundle_version_update}" != "true" ]]; then
    echo "Release candidate ${candidate_sha} must update bundle/bundle.json." >&2
    exit 1
  fi
}

verify_generated_bundle() {
  bash scripts/verify-bundle.sh
}

verify_required_rollup() {
  local rollup
  local owner="${repository%%/*}"
  local name="${repository#*/}"
  local cursor="null"
  local has_next_page
  local end_cursor

  while :; do
    rollup="$(gh api graphql \
    -f query='query($owner: String!, $name: String!, $expression: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        object(expression: $expression) {
          ... on Commit {
            statusCheckRollup {
              contexts(first: 100, after: $cursor) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  ... on CheckRun {
                    name
                    conclusion
                    checkSuite {
                      app {
                        databaseId
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }' \
    -F owner="${owner}" \
    -F name="${name}" \
    -F expression="${resolved_expected_sha}" \
    -F cursor="${cursor}")"

    if jq -e '
      .data.repository.object.statusCheckRollup.contexts.nodes
      | any(.name == "required"
        and .conclusion == "SUCCESS"
        and .checkSuite.app.databaseId == 15368)
    ' <<< "${rollup}" >/dev/null; then
      return 0
    fi

    has_next_page="$(jq -er '.data.repository.object.statusCheckRollup.contexts.pageInfo.hasNextPage' <<< "${rollup}")"
    if [[ "${has_next_page}" != "true" ]]; then
      break
    fi

    end_cursor="$(jq -er '.data.repository.object.statusCheckRollup.contexts.pageInfo.endCursor' <<< "${rollup}")"
    cursor="${end_cursor}"
  done

  echo "Commit ${resolved_expected_sha} does not have a successful required GitHub Actions check rollup." >&2
  exit 1
}

wait_for_push_verification() {
  local verification_ref="$1"
  local verification_runs
  local verification_run_id=""
  local verification_run

  for _ in {1..60}; do
    verification_runs="$(gh run list \
      --repo "${repository}" \
      --workflow verify.yaml \
      --branch "${verification_ref}" \
      --commit "${resolved_expected_sha}" \
      --event push \
      --limit 10 \
      --json databaseId,createdAt)"
    verification_run_id="$(jq -r 'sort_by(.createdAt) | last | .databaseId // empty' <<< "${verification_runs}")"
    if [[ -n "${verification_run_id}" ]]; then
      break
    fi

    sleep 2
  done

  if [[ -z "${verification_run_id}" ]]; then
    echo "Timed out waiting for a push verification run for ${verification_ref} at ${resolved_expected_sha}; workflow_dispatch is not promotion evidence." >&2
    exit 1
  fi

  gh run watch "${verification_run_id}" --repo "${repository}" --exit-status
  verification_run="$(gh run view \
    "${verification_run_id}" \
    --repo "${repository}" \
    --json workflowName,event,headSha,status,conclusion,jobs)"

  if ! jq -e \
    --arg expected_sha "${resolved_expected_sha}" \
    '.workflowName == "verify"
      and .event == "push"
      and .headSha == $expected_sha
      and .status == "completed"
      and .conclusion == "success"
      and any(.jobs[]; .name == "required" and .conclusion == "success")' \
    <<< "${verification_run}" >/dev/null; then
    echo "Push verification run ${verification_run_id} did not successfully verify ${verification_ref} at ${resolved_expected_sha}." >&2
    exit 1
  fi

  verify_required_rollup
}

resolved_expected_sha="$(git rev-parse --verify --end-of-options "${expected_sha}^{commit}")"
current_sha="$(git rev-parse HEAD)"
if [[ "${current_sha}" != "${resolved_expected_sha}" ]]; then
  echo "Current commit ${current_sha} does not match expected release commit ${resolved_expected_sha}." >&2
  exit 1
fi

validate_candidate "${resolved_expected_sha}"
verify_generated_bundle

master_before="$(ref_sha "${default_branch}")"
release_before="$(ref_sha "${release_branch}")"
if [[ "${release_before}" != "${resolved_expected_sha}" ]]; then
  echo "Release branch ${release_branch} must point to ${resolved_expected_sha}; actual: ${release_before}." >&2
  exit 1
fi

if [[ "${mode}" == "promote" ]]; then
  if [[ "${master_before}" != "${candidate_base_sha}" ]]; then
    echo "Release candidate must remain a direct child of ${default_branch} at ${candidate_base_sha} and match ${release_branch}." >&2
    exit 1
  fi

  verification_ref="${release_branch}"
else
  if [[ "${master_before}" != "${resolved_expected_sha}" ]]; then
    echo "Promoted release candidate ${resolved_expected_sha} is not the current ${default_branch} tip: ${master_before}." >&2
    exit 1
  fi

  verification_ref="${default_branch}"
fi

IFS=$'\t' read -r latest_release_id_before latest_release_tag_before latest_release_target_before < <(latest_release)
wait_for_push_verification "${verification_ref}"
master_after_verification="$(ref_sha "${default_branch}")"
release_after_verification="$(ref_sha "${release_branch}")"
IFS=$'\t' read -r latest_release_id_after latest_release_tag_after latest_release_target_after < <(latest_release)

if [[ "${master_after_verification}" != "${master_before}" \
  || "${latest_release_id_after}" != "${latest_release_id_before}" \
  || "${latest_release_tag_after}" != "${latest_release_tag_before}" \
  || "${latest_release_target_after}" != "${latest_release_target_before}" \
  || "${release_after_verification}" != "${resolved_expected_sha}" ]]; then
  echo "Release refs or latest published release changed during verification." >&2
  exit 1
fi

if [[ "${mode}" == "promote" ]]; then
  GH_TOKEN="${RELEASE_BOT_TOKEN}" gh api \
    --method PATCH \
    "repos/${repository}/git/refs/heads/${default_branch}" \
    -f sha="${resolved_expected_sha}" \
    -F force=false >/dev/null

  promoted_sha="$(ref_sha "${default_branch}")"
  if [[ "${promoted_sha}" != "${resolved_expected_sha}" ]]; then
    echo "Default branch ${default_branch} did not advance to ${resolved_expected_sha}; actual: ${promoted_sha}." >&2
    exit 1
  fi

  master_before="${promoted_sha}"
  release_before="${release_after_verification}"
  IFS=$'\t' read -r latest_release_id_before latest_release_tag_before latest_release_target_before < <(latest_release)
  wait_for_push_verification "${default_branch}"
  master_after_verification="$(ref_sha "${default_branch}")"
  release_after_verification="$(ref_sha "${release_branch}")"
  IFS=$'\t' read -r latest_release_id_after latest_release_tag_after latest_release_target_after < <(latest_release)

  if [[ "${master_after_verification}" != "${resolved_expected_sha}" \
    || "${release_after_verification}" != "${resolved_expected_sha}" \
    || "${latest_release_id_after}" != "${latest_release_id_before}" \
    || "${latest_release_tag_after}" != "${latest_release_tag_before}" \
    || "${latest_release_target_after}" != "${latest_release_target_before}" ]]; then
    echo "Release refs or latest published release changed after promotion." >&2
    exit 1
  fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "release_sha=${resolved_expected_sha}" >> "${GITHUB_OUTPUT}"
else
  echo "${resolved_expected_sha}"
fi
