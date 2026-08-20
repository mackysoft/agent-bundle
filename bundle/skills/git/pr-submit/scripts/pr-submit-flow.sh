#!/bin/sh

export GIT_OPTIONAL_LOCKS=0
export GIT_PAGER=cat
export PAGER=cat
export GIT_TERMINAL_PROMPT=0
export GIT_EXTERNAL_DIFF=:

worktree=
base_ref=

emit() {
    printf '{"schemaVersion":1,"outcome":"%s","reason":"%s","result":%s}\n' \
        "$1" "$2" "$3"
}

is_oid() {
    case "$1" in ''|*[!0123456789abcdef]*) return 1 ;; esac
    case ${#1} in 40|64) return 0 ;; *) return 1 ;; esac
}

json_oid() {
    if is_oid "$1"; then printf '"%s"' "$1"; else printf 'null'; fi
}

is_literal_ref() {
    case "$1" in refs/heads/?*|refs/tags/?*|refs/remotes/?*/?*) ;; *) return 1 ;; esac
    case "$1" in *'@{'*|*'^'*|*'~'*|*':'*|*'..'*|*'//'*) return 1 ;; esac
    git check-ref-format "$1" >/dev/null 2>&1
}

json_ref() {
    if is_literal_ref "$1"; then
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

resolve_ref_oid() {
    resolved_oid=
    if git show-ref --verify --quiet "$1"; then
        candidate_oid=$(git rev-parse "$1^{commit}" 2>/dev/null) || return 1
        is_oid "$candidate_oid" || return 1
        resolved_oid=$candidate_oid
        return 0
    fi
    return 2
}

resolve_head() {
    head_ref=$(git symbolic-ref -q HEAD 2>/dev/null) || head_ref=
    if [ -n "$head_ref" ]; then
        if resolve_ref_oid "$head_ref"; then
            head_state=attached
            head_oid=$resolved_oid
        else
            head_state=unborn
            head_oid=
        fi
    else
        head_oid=$(git rev-parse HEAD 2>/dev/null) || head_oid=
        if is_oid "$head_oid"; then
            head_state=detached
        else
            head_state=unborn
            head_oid=
        fi
    fi
}

collect_local() {
    resolve_head
    status_text=$(git status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || return 1
    if [ -n "$status_text" ]; then
        has_changes=true
    else
        has_changes=false
    fi
    unmerged_text=$(git ls-files -u 2>/dev/null) || return 1
    if [ -n "$unmerged_text" ]; then has_unmerged=true; else has_unmerged=false; fi
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

compare_base() {
    base_oid=
    base_relation=
    base_ahead=
    base_behind=
    base_tree_changes=null
    if ! resolve_ref_oid "$base_ref"; then return 0; fi
    base_oid=$resolved_oid
    is_oid "$head_oid" || return 0

    merge_base=$(git merge-base "$head_oid" "$base_oid" 2>/dev/null) || merge_base=
    if ! is_oid "$merge_base"; then
        base_relation=unrelated
        git diff --quiet --no-ext-diff "$base_oid" "$head_oid" -- >/dev/null 2>&1
        case "$?" in
            0) base_tree_changes=false ;;
            1) base_tree_changes=true ;;
            *) return 1 ;;
        esac
        return 0
    fi

    counts=$(git rev-list --left-right --count "$head_oid...$base_oid" 2>/dev/null) || return 1
    set -- $counts
    [ "$#" -eq 2 ] || return 1
    case "$1:$2" in *[!0-9:]*|:) return 1 ;; esac
    base_ahead=$1
    base_behind=$2
    if [ "$base_ahead" -eq 0 ] && [ "$base_behind" -eq 0 ]; then
        base_relation=equal
    elif [ "$base_ahead" -gt 0 ] && [ "$base_behind" -eq 0 ]; then
        base_relation=head-ahead
    elif [ "$base_ahead" -eq 0 ] && [ "$base_behind" -gt 0 ]; then
        base_relation=ref-ahead
    else
        base_relation=diverged
    fi
    git diff --quiet --no-ext-diff "$base_oid" "$head_oid" -- >/dev/null 2>&1
    case "$?" in
        0) base_tree_changes=false ;;
        1) base_tree_changes=true ;;
        *) return 1 ;;
    esac
}

collect_publication() {
    origin_configured=false
    if git remote get-url origin >/dev/null 2>&1; then origin_configured=true; fi
    [ "$head_state" = attached ] || return 0
    [ "$origin_configured" = true ] || return 0

    remote_query=$(git ls-remote --heads origin "$head_ref" 2>/dev/null) || return 2
    [ -n "$remote_query" ] || return 0
    set -- $remote_query
    [ "$#" -eq 2 ] || return 1
    [ "$2" = "$head_ref" ] || return 1
    is_oid "$1" || return 1
}

result_json() {
    printf '{"headRef":'
    json_ref "$head_ref"
    printf ',"headOid":'
    json_oid "$head_oid"
    printf ',"baseRef":'
    json_ref "$base_ref"
    printf ',"baseOid":'
    json_oid "$base_oid"
    printf '}'
}

if ! command -v git >/dev/null 2>&1; then
    emit runtime-unavailable git-not-found null
    exit 0
fi
if [ "$#" -ne 5 ] || [ "$1" != prepare ] || [ "$2" != --worktree ] || [ "$4" != --base-ref ]; then
    emit input-invalid invalid-arguments null
    exit 0
fi
validate_worktree "$3" || {
    emit input-invalid invalid-worktree null
    exit 0
}
base_ref=$5
is_literal_ref "$base_ref" || {
    emit input-invalid invalid-base-ref null
    exit 0
}

cd "$worktree" 2>/dev/null || {
    emit blocked unable-to-enter-worktree null
    exit 0
}
repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    emit blocked not-git-worktree null
    exit 0
}
repository_root=$(CDPATH= cd "$repository_root" 2>/dev/null && pwd -P) || {
    emit blocked repository-root-unavailable null
    exit 0
}
[ "$repository_root" = "$worktree" ] || {
    emit blocked worktree-root-mismatch null
    exit 0
}
collect_local || {
    emit blocked git-observation-failed null
    exit 0
}
detect_operation || {
    emit blocked git-observation-failed null
    exit 0
}
compare_base || {
    emit blocked git-comparison-failed null
    exit 0
}
collect_publication
publication_rc=$?
case "$publication_rc" in
    0) ;;
    2)
        emit blocked remote-unavailable null
        exit 0
        ;;
    *)
        emit blocked git-observation-failed null
        exit 0
        ;;
esac
result=$(result_json)

case "$operation_state" in
    unknown-or-unsupported)
        emit blocked unknown-or-unsupported-operation "$result"
        exit 0
        ;;
    none)
        ;;
    *)
        emit blocked operation-in-progress "$result"
        exit 0
        ;;
esac
if [ "$has_unmerged" = true ]; then
    emit blocked unmerged "$result"
elif [ "$head_state" = detached ]; then
    emit blocked detached-head "$result"
elif [ "$head_state" = unborn ]; then
    emit blocked unborn-head "$result"
elif ! is_oid "$base_oid"; then
    emit blocked base-ref-unresolved "$result"
elif [ "$base_relation" = unrelated ]; then
    emit blocked unrelated-base "$result"
elif [ "$has_changes" = false ] && { [ "$base_tree_changes" = false ] || [ "$base_ahead" = 0 ]; }; then
    emit no-op no-change "$result"
elif [ "$origin_configured" = false ]; then
    emit blocked origin-not-configured "$result"
else
    emit completed ready "$result"
fi
