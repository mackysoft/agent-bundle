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

emit() {
    printf '{"schemaVersion":1,"outcome":"%s","reason":"%s","result":%s}\n' "$1" "$2" "$3"
}

is_oid() {
    case "$1" in ''|*[!0123456789abcdef]*) return 1 ;; esac
    case ${#1} in 40|64) return 0 ;; *) return 1 ;; esac
}

json_oid() {
    if is_oid "$1"; then printf '"%s"' "$1"; else printf 'null'; fi
}

is_branch_ref() {
    case "$1" in refs/heads/?*) ;; *) return 1 ;; esac
    case "$1" in *'@{'*|*'^'*|*'~'*|*':'*|*'..'*|*'//'*) return 1 ;; esac
    git check-ref-format "$1" >/dev/null 2>&1
}

json_ref() {
    if is_branch_ref "$1"; then
        escaped_ref=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' 2>/dev/null) || {
            printf 'null'
            return
        }
        printf '"%s"' "$escaped_ref"
    else
        printf 'null'
    fi
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

result_json() {
    printf '{"head":{"state":"%s","ref":' "$head_state"
    json_ref "$head_ref"
    printf ',"oid":'
    json_oid "$head_oid"
    printf '},"originConfigured":%s,"upstream":{"configured":%s,"ref":' "$origin_configured" "$upstream_configured"
    json_ref "$upstream_ref"
    printf '},"hasChanges":%s,"hasUnmerged":%s,"operation":"%s","publishedRef":' \
        "$has_changes" "$has_unmerged" "$operation_state"
    json_ref "$published_ref"
    printf ',"remoteOid":'
    json_oid "$remote_oid"
    printf '}'
}

emit_current() {
    outcome=$1
    reason=$2
    result=$(result_json) || { emit unknown-after-attempt result-unavailable null; exit 0; }
    emit "$outcome" "$reason" "$result"
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
    emit runtime-unavailable git-not-found null
    exit 0
fi
[ "$#" -eq 3 ] && [ "$1" = publish-current ] && [ "$2" = --worktree ] || {
    emit input-invalid invalid-arguments null
    exit 0
}
validate_worktree "$3" || { emit input-invalid invalid-worktree null; exit 0; }
cd "$worktree" 2>/dev/null || { emit blocked worktree-unavailable null; exit 0; }
repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || { emit blocked not-git-worktree null; exit 0; }
repository_root=$(CDPATH= cd "$repository_root" 2>/dev/null && pwd -P) || { emit blocked repository-root-unavailable null; exit 0; }
[ "$repository_root" = "$worktree" ] || { emit input-invalid worktree-root-mismatch null; exit 0; }

observe_publish_state || { emit blocked state-unavailable null; exit 0; }
block_if_unsafe
select_publish_target
select_status=$?
case "$select_status" in
    0) ;;
    1) emit_current blocked upstream-invalid ;;
    *) emit_current blocked origin-not-configured ;;
esac
remote_head_oid "$publish_remote" "$published_ref" || emit_current blocked remote-unavailable
if [ "$initial_push" = false ] && [ "$remote_oid" = "$head_oid" ]; then emit_current no-op no-commits-to-push; fi

observe_publish_state || { emit blocked state-unavailable null; exit 0; }
block_if_unsafe
select_publish_target
select_status=$?
case "$select_status" in
    0) ;;
    1) emit_current blocked upstream-invalid ;;
    *) emit_current blocked origin-not-configured ;;
esac
source_oid=$head_oid
remote_head_oid "$publish_remote" "$published_ref" || emit_current blocked remote-unavailable
if [ "$initial_push" = false ] && [ "$remote_oid" = "$source_oid" ]; then emit_current no-op no-commits-to-push; fi

if [ "$initial_push" = true ]; then
    if push_output=$(git push -u origin "$head_ref:$head_ref" 2>&1); then push_status=0; else push_status=$?; fi
else
    if push_output=$(git push "$publish_remote" "$head_ref:$published_ref" 2>&1); then push_status=0; else push_status=$?; fi
fi
observe_publish_state || { emit unknown-after-attempt postcondition-unavailable null; exit 0; }
remote_head_oid "$publish_remote" "$published_ref" || emit_current unknown-after-attempt postcondition-unavailable
if [ "$push_status" -eq 0 ] && [ "$remote_oid" = "$source_oid" ]; then
    if [ "$initial_push" = true ] && { [ "$upstream_configured" = false ] || [ "$upstream_valid" = false ] || [ "$upstream_remote" != origin ] || [ "$upstream_ref" != "$head_ref" ]; }; then
        emit_current unknown-after-attempt upstream-postcondition-failed
    fi
    emit_current completed published
fi
if [ "$push_status" -ne 0 ]; then
    case "$push_output" in
        *non-fast-forward*|*'fetch first'*|*'[rejected]'*) emit_current blocked non-fast-forward ;;
    esac
    emit_current unknown-after-attempt push-failed
fi
emit_current unknown-after-attempt push-postcondition-failed
