#!/bin/sh

export GIT_OPTIONAL_LOCKS=0
export GIT_PAGER=cat
export PAGER=cat
export GIT_TERMINAL_PROMPT=0
export GIT_EXTERNAL_DIFF=:
export GIT_EDITOR=:

worktree=
published_ref=
remote_oid=
required_ref_list=

emit() {
    printf '{"outcome":"%s","reason":"%s"}\n' "$1" "$2"
}

is_oid() {
    case "$1" in ''|*[!0123456789abcdef]*) return 1 ;; esac
    case ${#1} in 40|64) return 0 ;; *) return 1 ;; esac
}

is_branch_ref() {
    case "$1" in refs/heads/?*) ;; *) return 1 ;; esac
    case "$1" in *'@{'*|*'^'*|*'~'*|*':'*|*'..'*|*'//'*) return 1 ;; esac
    git check-ref-format "$1" >/dev/null 2>&1
}

is_remote_tracking_ref() {
    case "$1" in refs/remotes/?*/?*) ;; *) return 1 ;; esac
    case "$1" in *'@{'*|*'^'*|*'~'*|*':'*|*'..'*|*'//'*) return 1 ;; esac
    git check-ref-format "$1" >/dev/null 2>&1
}

validate_worktree() {
    case "$1" in /*) ;; *) return 1 ;; esac
    [ -d "$1" ] || return 1
    physical_root=$(CDPATH= cd "$1" 2>/dev/null && pwd -P) || return 1
    [ "$physical_root" = "$1" ] || return 1
    worktree=$physical_root
}

resolve_head() {
    head_ref=$(git symbolic-ref -q HEAD 2>/dev/null)
    if [ -n "$head_ref" ]; then
        head_oid=$(git rev-parse "$head_ref^{commit}" 2>/dev/null) || head_oid=
        if is_oid "$head_oid"; then
            head_state=attached
        else
            head_state=unborn
            head_oid=
        fi
    else
        head_oid=$(git rev-parse HEAD 2>/dev/null) || head_oid=
        if is_oid "$head_oid"; then head_state=detached; else head_state=unborn; head_oid=; fi
    fi
}

detect_operation() {
    git_dir_raw=$(git rev-parse --git-dir 2>/dev/null) || return 1
    git_dir=$(CDPATH= cd "$git_dir_raw" 2>/dev/null && pwd -P) || return 1
    operation_state=none
    operation_count=0
    unsupported_operation=false
    if [ -f "$git_dir/MERGE_HEAD" ]; then operation_state=merge; operation_count=$((operation_count + 1)); fi
    if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then operation_state=rebase; operation_count=$((operation_count + 1)); fi
    if [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then operation_state=cherry-pick; operation_count=$((operation_count + 1)); fi
    if [ -f "$git_dir/REVERT_HEAD" ]; then operation_state=revert; operation_count=$((operation_count + 1)); fi
    if [ -d "$git_dir/sequencer" ]; then operation_state=sequencer; operation_count=$((operation_count + 1)); fi
    if [ -f "$git_dir/BISECT_LOG" ] || [ -f "$git_dir/BISECT_START" ] || [ -f "$git_dir/AM_HEAD" ]; then unsupported_operation=true; fi
    if [ "$operation_count" -gt 1 ] || [ "$unsupported_operation" = true ]; then operation_state=unknown-or-unsupported; fi
}

remote_exists() {
    git remote 2>/dev/null | grep -F -x -- "$1" >/dev/null 2>&1
}

collect_upstream() {
    upstream_configured=false
    upstream_valid=false
    upstream_remote=
    upstream_ref=
    [ "$head_state" = attached ] || return 0
    head_branch=${head_ref#refs/heads/}
    configured_remote=$(git config --get "branch.$head_branch.remote" 2>/dev/null) || configured_remote=
    configured_merge=$(git config --get "branch.$head_branch.merge" 2>/dev/null) || configured_merge=
    [ -n "$configured_remote" ] || [ -n "$configured_merge" ] || return 0
    upstream_configured=true
    upstream_remote=$configured_remote
    upstream_ref=$configured_merge
    case "$upstream_remote" in ''|-*) return 0 ;; esac
    is_branch_ref "$upstream_ref" || return 0
    remote_exists "$upstream_remote" || return 0
    upstream_valid=true
}

observe_publish_state() {
    resolve_head
    detect_operation || return 1
    status_text=$(git status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || return 1
    if [ -n "$status_text" ]; then has_changes=true; else has_changes=false; fi
    unmerged_text=$(git ls-files -u 2>/dev/null) || return 1
    if [ -n "$unmerged_text" ]; then has_unmerged=true; else has_unmerged=false; fi
    if remote_exists origin; then origin_configured=true; else origin_configured=false; fi
    collect_upstream
}

remote_head_oid() {
    remote_name=$1
    remote_ref=$2
    remote_oid=
    remote_line=$(git ls-remote --heads "$remote_name" "$remote_ref" 2>/dev/null) || return 1
    [ -z "$remote_line" ] && return 0
    set -- $remote_line
    [ "$#" -eq 2 ] || return 1
    is_oid "$1" || return 1
    [ "$2" = "$remote_ref" ] || return 1
    remote_oid=$1
}

parse_required_ref() {
    is_remote_tracking_ref "$1" || return 1
    required_ref=$1
    required_tail=${required_ref#refs/remotes/}
    required_remote=${required_tail%%/*}
    required_branch=${required_tail#*/}
    [ -n "$required_remote" ] && [ -n "$required_branch" ] && [ "$required_branch" != "$required_tail" ] || return 1
    case "$required_remote" in -*) return 1 ;; esac
    required_branch_ref="refs/heads/$required_branch"
    is_branch_ref "$required_branch_ref" || return 1
}

fetch_remote() {
    git fetch --prune "$1" >/dev/null 2>&1
}

resolve_required_ref_oid() {
    required_oid=
    if git show-ref --verify --quiet "$required_ref"; then
        candidate_oid=$(git rev-parse "$required_ref^{commit}" 2>/dev/null) || return 1
        is_oid "$candidate_oid" || return 1
        required_oid=$candidate_oid
        return 0
    fi
    return 2
}

check_required_refs_integrated() {
    while IFS= read -r listed_ref; do
        [ -n "$listed_ref" ] || continue
        parse_required_ref "$listed_ref" || emit_current input-invalid invalid-required-integrated-ref
        remote_exists "$required_remote" || emit_current blocked required-remote-not-configured
    done <<EOF
$required_ref_list
EOF

    while IFS= read -r listed_ref; do
        [ -n "$listed_ref" ] || continue
        parse_required_ref "$listed_ref" || emit_current input-invalid invalid-required-integrated-ref
        fetch_remote "$required_remote" || emit_current blocked remote-unavailable
    done <<EOF
$required_ref_list
EOF

    while IFS= read -r listed_ref; do
        [ -n "$listed_ref" ] || continue
        parse_required_ref "$listed_ref" || emit_current input-invalid invalid-required-integrated-ref
        resolve_required_ref_oid
        resolve_status=$?
        case "$resolve_status" in
            0) ;;
            2) emit_current blocked required-ref-unresolved ;;
            *) emit_current blocked comparison-unavailable ;;
        esac
        git merge-base --is-ancestor "$required_oid" "$source_oid" >/dev/null 2>&1 \
            || emit_current blocked sync-required
    done <<EOF
$required_ref_list
EOF
}

emit_current() {
    outcome=$1
    reason=$2
    emit "$outcome" "$reason"
    exit 0
}

block_if_unsafe() {
    case "$operation_state" in
        none) ;;
        unknown-or-unsupported) emit_current blocked unknown-or-unsupported-operation ;;
        *) emit_current blocked operation-in-progress ;;
    esac
    if [ "$has_unmerged" = true ]; then emit_current blocked unmerged; fi
    if [ "$head_state" = detached ]; then emit_current blocked detached-head; fi
    if [ "$head_state" = unborn ]; then emit_current blocked unborn-head; fi
    if [ "$has_changes" = true ]; then emit_current blocked commit-required; fi
}

select_publish_target() {
    initial_push=false
    if [ "$upstream_configured" = true ]; then
        [ "$upstream_valid" = true ] || return 1
        publish_remote=$upstream_remote
        published_ref=$upstream_ref
    else
        [ "$origin_configured" = true ] || return 2
        publish_remote=origin
        published_ref=$head_ref
        initial_push=true
    fi
    is_branch_ref "$published_ref" || return 1
}

if ! command -v git >/dev/null 2>&1; then
    emit runtime-unavailable git-not-found
    exit 0
fi
[ "${1-}" = publish-current ] || { emit input-invalid invalid-operation; exit 0; }
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --worktree)
            [ "$#" -ge 2 ] && [ -z "$worktree" ] || { emit input-invalid invalid-arguments; exit 0; }
            validate_worktree "$2" || { emit input-invalid invalid-worktree; exit 0; }
            shift 2
            ;;
        --require-integrated-ref)
            [ "$#" -ge 2 ] || { emit input-invalid invalid-arguments; exit 0; }
            is_remote_tracking_ref "$2" || { emit input-invalid invalid-required-integrated-ref; exit 0; }
            required_ref_list="${required_ref_list}${2}
"
            shift 2
            ;;
        *)
            emit input-invalid invalid-arguments
            exit 0
            ;;
    esac
done
[ -n "$worktree" ] || { emit input-invalid missing-worktree; exit 0; }
cd "$worktree" 2>/dev/null || { emit blocked worktree-unavailable; exit 0; }
repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || { emit blocked not-git-worktree; exit 0; }
repository_root=$(CDPATH= cd "$repository_root" 2>/dev/null && pwd -P) || { emit blocked repository-root-unavailable; exit 0; }
[ "$repository_root" = "$worktree" ] || { emit input-invalid worktree-root-mismatch; exit 0; }

observe_publish_state || { emit blocked state-unavailable; exit 0; }
block_if_unsafe
select_publish_target
select_status=$?
case "$select_status" in
    0) ;;
    1) emit_current blocked upstream-invalid ;;
    *) emit_current blocked origin-not-configured ;;
esac
source_oid=$head_oid
check_required_refs_integrated

fetch_remote "$publish_remote" || emit_current blocked remote-unavailable
remote_head_oid "$publish_remote" "$published_ref" || emit_current blocked remote-unavailable
if [ "$initial_push" = false ] && [ "$remote_oid" = "$source_oid" ]; then emit_current no-op no-commits-to-push; fi
if [ -n "$remote_oid" ] \
    && ! git merge-base --is-ancestor "$remote_oid" "$source_oid" >/dev/null 2>&1; then
    emit_current blocked sync-required
fi

if [ "$initial_push" = true ]; then
    if push_output=$(git push -u origin "$head_ref:$head_ref" 2>&1); then push_status=0; else push_status=$?; fi
else
    if push_output=$(git push "$publish_remote" "$head_ref:$published_ref" 2>&1); then push_status=0; else push_status=$?; fi
fi
observe_publish_state || { emit unknown-after-attempt postcondition-unavailable; exit 0; }
remote_head_oid "$publish_remote" "$published_ref" || emit_current unknown-after-attempt postcondition-unavailable
if [ "$push_status" -eq 0 ] && [ "$remote_oid" = "$source_oid" ]; then
    if [ "$initial_push" = true ] && { [ "$upstream_configured" = false ] || [ "$upstream_valid" = false ] || [ "$upstream_remote" != origin ] || [ "$upstream_ref" != "$head_ref" ]; }; then
        emit_current unknown-after-attempt upstream-postcondition-failed
    fi
    emit_current completed published
fi
if [ "$push_status" -ne 0 ]; then
    case "$push_output" in
        *non-fast-forward*|*'fetch first'*|*'[rejected]'*)
            if fetch_remote "$publish_remote" \
                && remote_head_oid "$publish_remote" "$published_ref" \
                && [ -n "$remote_oid" ] \
                && ! git merge-base --is-ancestor "$remote_oid" "$source_oid" >/dev/null 2>&1; then
                emit_current blocked sync-required
            fi
            emit_current blocked non-fast-forward
            ;;
    esac
    emit_current unknown-after-attempt push-failed
fi
emit_current unknown-after-attempt push-postcondition-failed
