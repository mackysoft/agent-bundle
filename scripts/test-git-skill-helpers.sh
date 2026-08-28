#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
temp_root=${TMPDIR:-/tmp}
fixture_root=$(mktemp -d "${temp_root%/}/git-skill-flows.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM
fixture_root=$(CDPATH= cd "$fixture_root" && pwd -P)

test_number=0
last_case=
last_output=
result_is_expected=false

fail() {
    printf '%s\n' "git skill flow test failed: $*" >&2
    exit 1
}

assert_equal() {
    [ "$1" = "$2" ] || fail "$last_case: expected $3 to be $2, got $1"
}

assert_json_string() {
    printf '%s\n' "$last_output" | grep -F -- "\"$1\":\"$2\"" >/dev/null \
        || fail "$last_case: expected JSON string $1=$2"
}

assert_envelope() {
    output_file=$1
    expected_outcome=$2
    expected_reason=$3
    line_count=$(awk 'END { print NR }' "$output_file")
    [ "$line_count" = 1 ] || fail "$last_case: stdout must contain exactly one JSON line"
    last_output=$(sed -n '1p' "$output_file")
    if [ "$result_is_expected" = true ]; then
        printf '%s\n' "$last_output" | grep -Eq '^\{"outcome":"[^"]+","reason":"[^"]+","result":\{.*\}\}$' \
            || fail "$last_case: stdout is not the flow JSON envelope with a result"
    else
        printf '%s\n' "$last_output" | grep -Eq '^\{"outcome":"[^"]+","reason":"[^"]+"\}$' \
            || fail "$last_case: stdout is not the minimal flow JSON envelope"
    fi
    for field in outcome reason; do
        printf '%s\n' "$last_output" | grep -F -- "\"$field\":" >/dev/null \
            || fail "$last_case: JSON envelope is missing $field"
    done
    assert_json_string outcome "$expected_outcome"
    assert_json_string reason "$expected_reason"
}

run_flow_with_result() {
    result_is_expected=true
    run_flow "$@"
    result_is_expected=false
}

run_flow() {
    last_case=$1
    helper=$2
    expected_outcome=$3
    expected_reason=$4
    shift 4

    test_number=$((test_number + 1))
    output_file="$fixture_root/output-$test_number.json"
    error_file="$fixture_root/error-$test_number.txt"
    if sh "$helper" "$@" > "$output_file" 2> "$error_file"; then
        :
    else
        command_status=$?
        sed 's/^/  /' "$error_file" >&2 || true
        fail "$last_case: expected a classified outcome with exit 0, got exit $command_status"
    fi
    assert_envelope "$output_file" "$expected_outcome" "$expected_reason"
}

run_flow_with_stdin() {
    last_case=$1
    helper=$2
    expected_outcome=$3
    expected_reason=$4
    message=$5
    shift 5

    test_number=$((test_number + 1))
    output_file="$fixture_root/output-$test_number.json"
    error_file="$fixture_root/error-$test_number.txt"
    if printf '%s\n' "$message" | sh "$helper" "$@" > "$output_file" 2> "$error_file"; then
        :
    else
        command_status=$?
        sed 's/^/  /' "$error_file" >&2 || true
        fail "$last_case: expected a classified outcome with exit 0, got exit $command_status"
    fi
    assert_envelope "$output_file" "$expected_outcome" "$expected_reason"
}

assert_clean() {
    clean_status=$(git -C "$1" status --porcelain)
    [ -z "$clean_status" ] || fail "$last_case: expected a clean worktree"
}

remote_ref_oid() {
    git ls-remote --heads "$1" "$2" | awk 'NR == 1 { print $1 }'
}

assert_remote_ref_oid() {
    remote_actual_oid=$(remote_ref_oid "$1" "$2")
    [ "$remote_actual_oid" = "$3" ] \
        || fail "$last_case: expected remote $2 to be $3, got ${remote_actual_oid:-absent}"
}

create_repository() {
    repository_path=$1
    remote_path=$2

    git init -q --bare "$remote_path"
    git init -q "$repository_path"
    git -C "$repository_path" config user.name 'Git Skill Flow Test'
    git -C "$repository_path" config user.email 'git-skill-flow-test@example.invalid'
    git -C "$repository_path" config core.autocrlf false
    printf '%s\n' initial > "$repository_path/README.md"
    git -C "$repository_path" add README.md
    git -C "$repository_path" commit -qm initial
    git -C "$repository_path" branch -M main
    git -C "$repository_path" remote add origin "$remote_path"
    git -C "$repository_path" push -q -u origin main
    git --git-dir="$remote_path" symbolic-ref HEAD refs/heads/main
    git -C "$repository_path" fetch -q origin
}

commit_file() {
    repository_path=$1
    file_path=$2
    contents=$3
    commit_message=$4

    parent_path=$(dirname "$repository_path/$file_path")
    mkdir -p "$parent_path"
    printf '%s\n' "$contents" > "$repository_path/$file_path"
    git -C "$repository_path" add -- "$file_path"
    git -C "$repository_path" commit -qm "$commit_message"
}

advance_remote_main() {
    updater_path=$1
    remote_path=$2
    file_path=$3
    contents=$4

    git clone -q "$remote_path" "$updater_path"
    git -C "$updater_path" config user.name 'Git Skill Flow Test'
    git -C "$updater_path" config user.email 'git-skill-flow-test@example.invalid'
    git -C "$updater_path" config core.autocrlf false
    commit_file "$updater_path" "$file_path" "$contents" 'advance main'
    git -C "$updater_path" push -q origin main
}

branch_create_flow="$repo_root/bundle/skills/git/branch-create/scripts/branch-create-flow.sh"
commit_flow="$repo_root/bundle/skills/git/commit/scripts/commit-flow.sh"
push_flow="$repo_root/bundle/skills/git/push/scripts/push-flow.sh"
pr_submit_flow="$repo_root/bundle/skills/git/pr-submit/scripts/pr-submit-flow.sh"
sync_latest_flow="$repo_root/bundle/skills/git/sync-latest/scripts/sync-latest-flow.sh"

for expected_flow in "$branch_create_flow" "$commit_flow" "$push_flow" \
    "$pr_submit_flow" "$sync_latest_flow"; do
    [ -f "$expected_flow" ] || fail "missing source asset: $expected_flow"
    sh -n "$expected_flow" || fail "invalid POSIX shell syntax: $expected_flow"
done

# One worktree covers the branch, commit, push, and PR preparation flows.
core_repository="$fixture_root/core"
core_remote="$fixture_root/core-origin.git"
create_repository "$core_repository" "$core_remote"

run_flow 'branch-create creates and attaches the requested branch' "$branch_create_flow" completed created \
    ensure --worktree "$core_repository" --branch-ref refs/heads/feature --base-ref refs/remotes/origin/main
assert_equal "$(git -C "$core_repository" symbolic-ref -q HEAD)" refs/heads/feature 'current branch'

printf '%s\n' feature > "$core_repository/feature.txt"
core_pre_commit_oid=$(git -C "$core_repository" rev-parse HEAD)
result_is_expected=true
run_flow_with_stdin 'commit stages and commits the selected path' "$commit_flow" completed committed 'feat: add feature' \
    create --worktree "$core_repository" --path feature.txt
result_is_expected=false
core_commit_oid=$(git -C "$core_repository" rev-parse HEAD)
[ "$core_commit_oid" != "$core_pre_commit_oid" ] || fail "$last_case: expected HEAD to change"
assert_equal "$last_output" "{\"outcome\":\"completed\",\"reason\":\"committed\",\"result\":{\"commitOid\":\"$core_commit_oid\"}}" 'commit result'
assert_clean "$core_repository"

run_flow 'push publishes the current branch and sets upstream' "$push_flow" completed published \
    publish-current --worktree "$core_repository"
assert_remote_ref_oid "$core_remote" refs/heads/feature "$core_commit_oid"
assert_equal "$(git -C "$core_repository" config --get branch.feature.remote)" origin 'feature upstream remote'
assert_equal "$(git -C "$core_repository" config --get branch.feature.merge)" refs/heads/feature 'feature upstream ref'
run_flow 'push rerun is a no-op after publication' "$push_flow" no-op no-commits-to-push \
    publish-current --worktree "$core_repository"

# An initial publish must not overwrite an existing same-name remote branch.
# It can establish upstream only when that branch is already included in HEAD.
initial_publish_repository="$fixture_root/initial-publish"
initial_publish_remote="$fixture_root/initial-publish-origin.git"
initial_publish_writer="$fixture_root/initial-publish-writer"
create_repository "$initial_publish_repository" "$initial_publish_remote"
git clone -q "$initial_publish_remote" "$initial_publish_writer"
git -C "$initial_publish_writer" config user.name 'Git Skill Flow Test'
git -C "$initial_publish_writer" config user.email 'git-skill-flow-test@example.invalid'
git -C "$initial_publish_writer" checkout -qb remote-only
commit_file "$initial_publish_writer" remote.txt remote 'remote-only'
git -C "$initial_publish_writer" push -q origin remote-only
initial_publish_remote_only_oid=$(remote_ref_oid "$initial_publish_remote" refs/heads/remote-only)

git -C "$initial_publish_repository" checkout -qb remote-only
commit_file "$initial_publish_repository" local.txt local 'local-only'
run_flow 'push blocks an initial publish behind an existing same-name remote branch' "$push_flow" blocked sync-required \
    publish-current --worktree "$initial_publish_repository"
assert_remote_ref_oid "$initial_publish_remote" refs/heads/remote-only "$initial_publish_remote_only_oid"
assert_equal "$(git -C "$initial_publish_repository" config --get branch.remote-only.remote 2>/dev/null || true)" '' \
    'blocked initial publish must not configure upstream'

git -C "$initial_publish_writer" checkout -qb remote-ancestor origin/main
commit_file "$initial_publish_writer" ancestor.txt ancestor 'remote ancestor'
git -C "$initial_publish_writer" push -q origin remote-ancestor
initial_publish_ancestor_oid=$(remote_ref_oid "$initial_publish_remote" refs/heads/remote-ancestor)
git -C "$initial_publish_repository" fetch -q origin
git -C "$initial_publish_repository" checkout -qb remote-ancestor refs/remotes/origin/remote-ancestor
git -C "$initial_publish_repository" config --unset-all branch.remote-ancestor.remote 2>/dev/null || true
git -C "$initial_publish_repository" config --unset-all branch.remote-ancestor.merge 2>/dev/null || true
run_flow 'push publishes an initial branch when the same-name remote branch is an ancestor' "$push_flow" completed published \
    publish-current --worktree "$initial_publish_repository"
assert_remote_ref_oid "$initial_publish_remote" refs/heads/remote-ancestor "$initial_publish_ancestor_oid"
assert_equal "$(git -C "$initial_publish_repository" config --get branch.remote-ancestor.remote)" origin \
    'initial publish upstream remote'
assert_equal "$(git -C "$initial_publish_repository" config --get branch.remote-ancestor.merge)" refs/heads/remote-ancestor \
    'initial publish upstream ref'

# Publication refuses to write until every explicitly required base has been
# integrated.  A remotely advanced configured upstream is the same sync gate.
push_gate_repository="$fixture_root/push-gates"
push_gate_remote="$fixture_root/push-gates-origin.git"
push_gate_main_updater="$fixture_root/push-gates-main-updater"
push_gate_branch_updater="$fixture_root/push-gates-branch-updater"
create_repository "$push_gate_repository" "$push_gate_remote"
git -C "$push_gate_repository" checkout -qb push-gate
commit_file "$push_gate_repository" feature.txt feature 'add feature'
advance_remote_main "$push_gate_main_updater" "$push_gate_remote" remote.txt remote
push_gate_before_sync=$(git -C "$push_gate_repository" rev-parse HEAD)
run_flow 'push requires an integrated base before initial publication' "$push_flow" blocked sync-required \
    publish-current --worktree "$push_gate_repository" \
    --require-integrated-ref refs/remotes/origin/main
assert_equal "$(git -C "$push_gate_repository" rev-parse HEAD)" "$push_gate_before_sync" 'push sync-required HEAD'
[ -z "$(remote_ref_oid "$push_gate_remote" refs/heads/push-gate)" ] \
    || fail "$last_case: push wrote the branch before the required base was integrated"
run_flow 'sync-latest integrates the required push base' "$sync_latest_flow" completed synchronized \
    synchronize --worktree "$push_gate_repository" --target-ref refs/remotes/origin/main
push_gate_published_oid=$(git -C "$push_gate_repository" rev-parse HEAD)
run_flow 'push publishes after the required base is integrated' "$push_flow" completed published \
    publish-current --worktree "$push_gate_repository" \
    --require-integrated-ref refs/remotes/origin/main
assert_remote_ref_oid "$push_gate_remote" refs/heads/push-gate "$push_gate_published_oid"

git clone -q "$push_gate_remote" "$push_gate_branch_updater"
git -C "$push_gate_branch_updater" config user.name 'Git Skill Flow Test'
git -C "$push_gate_branch_updater" config user.email 'git-skill-flow-test@example.invalid'
git -C "$push_gate_branch_updater" config core.autocrlf false
git -C "$push_gate_branch_updater" checkout -qb push-gate origin/push-gate
commit_file "$push_gate_branch_updater" remote-feature.txt remote 'remote feature change'
git -C "$push_gate_branch_updater" push -q origin push-gate
push_gate_remote_ahead_oid=$(remote_ref_oid "$push_gate_remote" refs/heads/push-gate)
commit_file "$push_gate_repository" local-feature.txt local 'local feature change'
run_flow 'push normalizes an advanced upstream to the sync gate before writing' "$push_flow" blocked sync-required \
    publish-current --worktree "$push_gate_repository"
assert_remote_ref_oid "$push_gate_remote" refs/heads/push-gate "$push_gate_remote_ahead_oid"

run_flow 'pr-submit prepares a changed branch for PR work' "$pr_submit_flow" completed ready \
    prepare --worktree "$core_repository" --base-ref refs/remotes/origin/main

# PR preparation never advances a dirty or base-behind worktree itself.  Once
# the two prerequisites are satisfied, it reports the worktree as ready.
pr_gate_repository="$fixture_root/pr-submit-gates"
pr_gate_remote="$fixture_root/pr-submit-gates-origin.git"
pr_gate_updater="$fixture_root/pr-submit-gates-updater"
create_repository "$pr_gate_repository" "$pr_gate_remote"
git -C "$pr_gate_repository" checkout -qb pr-gate
commit_file "$pr_gate_repository" feature.txt feature 'add feature'
printf '%s\n' dirty >> "$pr_gate_repository/feature.txt"
pr_gate_dirty_head=$(git -C "$pr_gate_repository" rev-parse HEAD)
run_flow 'pr-submit requires a commit before preparing a dirty worktree' "$pr_submit_flow" blocked commit-required \
    prepare --worktree "$pr_gate_repository" --base-ref refs/remotes/origin/main
assert_equal "$(git -C "$pr_gate_repository" rev-parse HEAD)" "$pr_gate_dirty_head" 'dirty worktree HEAD'
git -C "$pr_gate_repository" checkout -- feature.txt

advance_remote_main "$pr_gate_updater" "$pr_gate_remote" remote.txt remote
git -C "$pr_gate_repository" fetch -q origin
pr_gate_before_sync=$(git -C "$pr_gate_repository" rev-parse HEAD)
run_flow 'pr-submit requires sync when the base is not integrated' "$pr_submit_flow" blocked sync-required \
    prepare --worktree "$pr_gate_repository" --base-ref refs/remotes/origin/main
assert_equal "$(git -C "$pr_gate_repository" rev-parse HEAD)" "$pr_gate_before_sync" 'sync-required HEAD'
run_flow 'sync-latest integrates the PR base before preparation' "$sync_latest_flow" completed synchronized \
    synchronize --worktree "$pr_gate_repository" --target-ref refs/remotes/origin/main
run_flow 'pr-submit reports a synchronized changed worktree as ready' "$pr_submit_flow" completed ready \
    prepare --worktree "$pr_gate_repository" --base-ref refs/remotes/origin/main

no_change_repository="$fixture_root/pr-submit-no-change"
no_change_remote="$fixture_root/pr-submit-no-change-origin.git"
create_repository "$no_change_repository" "$no_change_remote"
run_flow 'pr-submit reports no change for an equal clean base' "$pr_submit_flow" no-op no-change \
    prepare --worktree "$no_change_repository" --base-ref refs/remotes/origin/main

# Synchronization applies an obvious fast-forward, then becomes a no-op once the
# target is already included.
sync_repository="$fixture_root/sync-success"
sync_remote="$fixture_root/sync-success-origin.git"
sync_updater="$fixture_root/sync-success-updater"
create_repository "$sync_repository" "$sync_remote"
git -C "$sync_repository" checkout -qb sync-feature
advance_remote_main "$sync_updater" "$sync_remote" remote.txt remote
sync_target_oid=$(remote_ref_oid "$sync_remote" refs/heads/main)
run_flow 'sync-latest fast-forwards the current branch to the fetched target' "$sync_latest_flow" completed synchronized \
    synchronize --worktree "$sync_repository" --target-ref refs/remotes/origin/main
assert_equal "$(git -C "$sync_repository" rev-parse HEAD)" "$sync_target_oid" 'synchronized HEAD'
run_flow 'sync-latest reports an already integrated target as a no-op' "$sync_latest_flow" no-op already-synchronized \
    synchronize --worktree "$sync_repository" --target-ref refs/remotes/origin/main

# A conflict is intentionally preserved; PR preparation must not bypass it.
conflict_repository="$fixture_root/sync-conflict"
conflict_remote="$fixture_root/sync-conflict-origin.git"
conflict_updater="$fixture_root/sync-conflict-updater"
create_repository "$conflict_repository" "$conflict_remote"
git -C "$conflict_repository" checkout -qb conflict-feature
commit_file "$conflict_repository" README.md local 'local README change'
conflict_head_oid=$(git -C "$conflict_repository" rev-parse HEAD)
advance_remote_main "$conflict_updater" "$conflict_remote" README.md remote
run_flow_with_result 'sync-latest preserves an unresolved merge conflict' "$sync_latest_flow" conflict merge-conflict \
    synchronize --worktree "$conflict_repository" --target-ref refs/remotes/origin/main
conflict_target_oid=$(git -C "$conflict_repository" rev-parse refs/remotes/origin/main)
conflict_merge_base_oid=$(git -C "$conflict_repository" merge-base "$conflict_head_oid" "$conflict_target_oid")
assert_equal "$last_output" "{\"outcome\":\"conflict\",\"reason\":\"merge-conflict\",\"result\":{\"preHeadOid\":\"$conflict_head_oid\",\"target\":{\"ref\":\"refs/remotes/origin/main\",\"oid\":\"$conflict_target_oid\",\"mergeBaseOid\":\"$conflict_merge_base_oid\"}}}" 'conflict result'
git -C "$conflict_repository" rev-parse -q --verify MERGE_HEAD >/dev/null \
    || fail "$last_case: conflict flow unexpectedly removed MERGE_HEAD"
[ -n "$(git -C "$conflict_repository" ls-files -u)" ] \
    || fail "$last_case: conflict flow unexpectedly removed unmerged index entries"
run_flow 'pr-submit blocks while a conflict remains unresolved' "$pr_submit_flow" blocked operation-in-progress \
    prepare --worktree "$conflict_repository" --base-ref refs/remotes/origin/main
git -C "$conflict_repository" rev-parse -q --verify MERGE_HEAD >/dev/null \
    || fail "$last_case: pr-submit changed the conflict operation"
[ -n "$(git -C "$conflict_repository" ls-files -u)" ] \
    || fail "$last_case: pr-submit changed the unmerged index"

printf '%s\n' 'Git Skill flow tests passed.'
