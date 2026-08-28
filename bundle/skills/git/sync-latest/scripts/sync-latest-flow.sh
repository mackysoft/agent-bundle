#!/bin/sh

export GIT_OPTIONAL_LOCKS=0
export GIT_PAGER=cat
export PAGER=cat
export GIT_TERMINAL_PROMPT=0
export GIT_EXTERNAL_DIFF=:
export GIT_EDITOR=:

worktree=
target_list=
target_count=0
newline='
'
pre_head_oid=
target_ref=
target_oid=
target_relation=null
target_ahead=null
target_behind=null
target_merge_base_oid=
changed=false

emit() {
    if [ "$#" -eq 3 ] && [ "$3" != null ]; then
        printf '{"outcome":"%s","reason":"%s","result":%s}\n' "$1" "$2" "$3"
    else
        printf '{"outcome":"%s","reason":"%s"}\n' "$1" "$2"
    fi
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

is_remote_ref() {
    case "$1" in refs/remotes/?*/?*) ;; *) return 1 ;; esac
    is_literal_ref "$1"
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

remote_exists() {
    git remote 2>/dev/null | grep -F -x -- "$1" >/dev/null 2>&1
}

parse_target_ref() {
    is_remote_ref "$1" || return 1
    target_ref=$1
    target_tail=${target_ref#refs/remotes/}
    target_remote=${target_tail%%/*}
    target_branch=${target_tail#*/}
    [ -n "$target_remote" ] && [ -n "$target_branch" ] && [ "$target_branch" != "$target_tail" ] || return 1
    case "$target_remote" in -*) return 1 ;; esac
    target_branch_ref="refs/heads/$target_branch"
    case "$target_branch_ref" in refs/heads/?*) ;; *) return 1 ;; esac
    git check-ref-format "$target_branch_ref" >/dev/null 2>&1
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

observe_sync_state() {
    resolve_head
    detect_operation || return 1
    status_text=$(git status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || return 1
    if [ -n "$status_text" ]; then has_changes=true; else has_changes=false; fi
    unmerged_text=$(git ls-files -u 2>/dev/null) || return 1
    if [ -n "$unmerged_text" ]; then has_unmerged=true; else has_unmerged=false; fi
}

prepare_target() {
    target_oid=
    target_relation=null
    target_ahead=null
    target_behind=null
    target_merge_base_oid=
    resolve_ref_oid "$target_ref"
    resolve_status=$?
    case "$resolve_status" in
        0) target_oid=$resolved_oid ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
    is_oid "$head_oid" || return 3
    merge_base=$(git merge-base "$head_oid" "$target_oid" 2>/dev/null)
    merge_status=$?
    case "$merge_status" in
        0) is_oid "$merge_base" || return 1 ;;
        1) target_relation='"unrelated"'; return 0 ;;
        *) return 1 ;;
    esac
    target_merge_base_oid=$merge_base
    counts=$(git rev-list --left-right --count "$head_oid...$target_oid" 2>/dev/null) || return 1
    set -- $counts
    [ "$#" -eq 2 ] || return 1
    case "$1:$2" in *[!0-9:]*|:) return 1 ;; esac
    target_ahead=$1
    target_behind=$2
    if [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; then
        target_relation='"equal"'
    elif [ "$1" -gt 0 ] && [ "$2" -eq 0 ]; then
        target_relation='"head-ahead"'
    elif [ "$1" -eq 0 ] && [ "$2" -gt 0 ]; then
        target_relation='"ref-ahead"'
    else
        target_relation='"diverged"'
    fi
}

target_is_integrated() {
    git merge-base --is-ancestor "$target_oid" "$head_oid" >/dev/null 2>&1
}

conflict_result_json() {
    printf '{"preHeadOid":'
    json_oid "$pre_head_oid"
    printf ',"target":{"ref":'
    json_ref "$target_ref"
    printf ',"oid":'
    json_oid "$target_oid"
    printf ',"mergeBaseOid":'
    json_oid "$target_merge_base_oid"
    printf '}}'
}

emit_current() {
    outcome=$1
    reason=$2
    if [ "$outcome" = conflict ] && [ "$reason" = merge-conflict ]; then
        result=$(conflict_result_json) || { emit unknown-after-attempt result-unavailable; exit 0; }
        emit "$outcome" "$reason" "$result"
    else
        emit "$outcome" "$reason"
    fi
    exit 0
}

block_if_start_unsafe() {
    case "$operation_state" in
        none) ;;
        unknown-or-unsupported) emit_current blocked unknown-or-unsupported-operation ;;
        *) emit_current blocked operation-in-progress ;;
    esac
    if [ "$has_unmerged" = true ]; then emit_current blocked unmerged; fi
    if [ "$head_state" = unborn ]; then emit_current blocked unborn-head; fi
}

append_applied_target() {
    changed=true
}

if ! command -v git >/dev/null 2>&1; then
    emit runtime-unavailable git-not-found null
    exit 0
fi
[ "${1-}" = synchronize ] || { emit input-invalid invalid-operation null; exit 0; }
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --worktree)
            [ "$#" -ge 2 ] && [ -z "$worktree" ] || { emit input-invalid invalid-arguments null; exit 0; }
            validate_worktree "$2" || { emit input-invalid invalid-worktree null; exit 0; }
            shift 2
            ;;
        --target-ref)
            [ "$#" -ge 2 ] || { emit input-invalid invalid-arguments null; exit 0; }
            is_remote_ref "$2" || { emit input-invalid invalid-target-ref null; exit 0; }
            target_list="${target_list}${2}
"
            target_count=$((target_count + 1))
            shift 2
            ;;
        *)
            emit input-invalid invalid-arguments null
            exit 0
            ;;
    esac
done
[ -n "$worktree" ] || { emit input-invalid missing-worktree null; exit 0; }
[ "$target_count" -gt 0 ] || { emit input-invalid missing-target-ref null; exit 0; }
cd "$worktree" 2>/dev/null || { emit blocked worktree-unavailable null; exit 0; }
repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || { emit blocked not-git-worktree null; exit 0; }
repository_root=$(CDPATH= cd "$repository_root" 2>/dev/null && pwd -P) || { emit blocked repository-root-unavailable null; exit 0; }
[ "$repository_root" = "$worktree" ] || { emit input-invalid worktree-root-mismatch null; exit 0; }

observe_sync_state || { emit blocked state-unavailable null; exit 0; }
pre_head_oid=$head_oid
block_if_start_unsafe

fetched_remotes=
while IFS= read -r listed_target; do
    [ -n "$listed_target" ] || continue
    parse_target_ref "$listed_target" || { target_ref=$listed_target; emit_current input-invalid invalid-target-ref; }
    remote_exists "$target_remote" || emit_current blocked target-remote-not-configured
    case " $fetched_remotes " in
        *" $target_remote "*) continue ;;
    esac
    observe_sync_state || emit_current blocked state-unavailable
    pre_head_oid=$head_oid
    block_if_start_unsafe
    if ! git fetch --prune "$target_remote" >/dev/null 2>&1; then
        observe_sync_state || emit_current blocked fetch-failed
        emit_current blocked fetch-failed
    fi
    fetched_remotes="$fetched_remotes $target_remote"
done <<EOF
$target_list
EOF

while IFS= read -r listed_target; do
    [ -n "$listed_target" ] || continue
    parse_target_ref "$listed_target" || { target_ref=$listed_target; emit_current input-invalid invalid-target-ref; }
    observe_sync_state || emit_current blocked state-unavailable
    pre_head_oid=$head_oid
    block_if_start_unsafe
    prepare_target
    prepare_status=$?
    case "$prepare_status" in
        0) ;;
        2) emit_current blocked target-ref-unresolved ;;
        3) emit_current blocked unborn-head ;;
        *) emit_current blocked comparison-unavailable ;;
    esac
    case "$target_relation" in
        '"equal"'|'"head-ahead"') continue ;;
        '"unrelated"') emit_current blocked unrelated-history ;;
    esac
    if [ "$head_state" = attached ] && [ "$head_ref" = "$target_branch_ref" ] && [ "$target_relation" = '"diverged"' ]; then
        emit_current blocked same-branch-diverged
    fi
    if [ "$has_changes" = true ]; then emit_current blocked commit-required; fi

    if [ "$head_state" = detached ]; then
        [ "$target_relation" = '"ref-ahead"' ] || emit_current blocked detached-diverged
        if git switch --detach "$target_oid" >/dev/null 2>&1; then switch_status=0; else switch_status=$?; fi
        observe_sync_state || emit_current unknown-after-attempt postcondition-unavailable
        if [ "$switch_status" -eq 0 ] && [ "$head_state" = detached ] && [ "$head_oid" = "$target_oid" ] \
            && [ "$operation_state" = none ] && [ "$has_unmerged" = false ]; then
            append_applied_target
            continue
        fi
        emit_current unknown-after-attempt detach-postcondition-failed
    fi

    if [ "$target_relation" = '"ref-ahead"' ]; then
        if git merge --ff-only "$target_oid" >/dev/null 2>&1; then merge_status=0; else merge_status=$?; fi
        observe_sync_state || emit_current unknown-after-attempt postcondition-unavailable
        if [ "$merge_status" -eq 0 ] && [ "$operation_state" = none ] && [ "$has_unmerged" = false ] \
            && [ "$head_oid" = "$target_oid" ]; then
            append_applied_target
            continue
        fi
        emit_current unknown-after-attempt fast-forward-postcondition-failed
    fi

    if git merge --no-edit "$target_oid" >/dev/null 2>&1; then merge_status=0; else merge_status=$?; fi
    observe_sync_state || emit_current unknown-after-attempt postcondition-unavailable
    if [ "$merge_status" -eq 0 ] && [ "$operation_state" = none ] && [ "$has_unmerged" = false ] && target_is_integrated; then
        append_applied_target
        continue
    fi
    if [ "$operation_state" = merge ] || [ "$has_unmerged" = true ]; then emit_current conflict merge-conflict; fi
    emit_current unknown-after-attempt merge-postcondition-failed
done <<EOF
$target_list
EOF

observe_sync_state || emit_current unknown-after-attempt postcondition-unavailable
block_if_start_unsafe
if [ "$changed" = true ]; then emit_current completed synchronized; fi
emit_current no-op already-synchronized
