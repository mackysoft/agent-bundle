#!/bin/sh

export GIT_OPTIONAL_LOCKS=0
export GIT_PAGER=cat
export PAGER=cat
export GIT_TERMINAL_PROMPT=0
export GIT_EXTERNAL_DIFF=:
export GIT_EDITOR=:

worktree=
path_list=
path_count=0
pre_head_oid=
commit_oid=
newline='
'
carriage_return=$(printf '\r')

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

validate_path() {
    case "$1" in ''|/*|\\*|.|./*|../*|*/../*|*/..|*'//'*) return 1 ;; esac
    case "$1" in *"$newline"*|*"$carriage_return"*) return 1 ;; esac
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

observe_commit_state() {
    resolve_head
    detect_operation || return 1
    status_text=$(git status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || return 1
    if [ -n "$status_text" ]; then has_changes=true; else has_changes=false; fi
    unmerged_text=$(git ls-files -u 2>/dev/null) || return 1
    if [ -n "$unmerged_text" ]; then has_unmerged=true; else has_unmerged=false; fi
    git diff --cached --quiet --no-ext-diff -- >/dev/null 2>&1
    case "$?" in
        0) has_staged_changes=false ;;
        1) has_staged_changes=true ;;
        *) return 1 ;;
    esac
}

result_json() {
    printf '{"head":{"state":"%s","ref":' "$head_state"
    json_ref "$head_ref"
    printf ',"oid":'
    json_oid "$head_oid"
    printf '},"hasChanges":%s,"hasStagedChanges":%s,"hasUnmerged":%s,"operation":"%s","preHeadOid":' \
        "$has_changes" "$has_staged_changes" "$has_unmerged" "$operation_state"
    json_oid "$pre_head_oid"
    printf ',"commitOid":'
    json_oid "$commit_oid"
    printf '}'
}

emit_current() {
    outcome=$1
    reason=$2
    result=$(result_json) || {
        emit unknown-after-attempt result-unavailable null
        exit 0
    }
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
    if [ -z "$head_ref" ] || [ "$head_state" = detached ]; then emit_current blocked detached-head; fi
}

stage_selected_paths() {
    (
        while IFS= read -r selected_path; do
            [ -n "$selected_path" ] || continue
            printf ':(literal)%s\0' "$selected_path"
        done <<EOF
$path_list
EOF
    ) | git add -A --pathspec-from-file=- --pathspec-file-nul >/dev/null 2>&1
}

if ! command -v git >/dev/null 2>&1; then
    emit runtime-unavailable git-not-found null
    exit 0
fi
[ "${1-}" = create ] || { emit input-invalid invalid-operation null; exit 0; }
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --worktree)
            [ "$#" -ge 2 ] && [ -z "$worktree" ] || { emit input-invalid invalid-arguments null; exit 0; }
            validate_worktree "$2" || { emit input-invalid invalid-worktree null; exit 0; }
            shift 2
            ;;
        --path)
            [ "$#" -ge 2 ] || { emit input-invalid invalid-arguments null; exit 0; }
            validate_path "$2" || { emit input-invalid invalid-path null; exit 0; }
            path_list="${path_list}${2}
"
            path_count=$((path_count + 1))
            shift 2
            ;;
        *)
            emit input-invalid invalid-arguments null
            exit 0
            ;;
    esac
done
[ -n "$worktree" ] || { emit input-invalid missing-worktree null; exit 0; }
[ "$path_count" -gt 0 ] || { emit input-invalid missing-path null; exit 0; }
cd "$worktree" 2>/dev/null || { emit blocked worktree-unavailable null; exit 0; }
repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || { emit blocked not-git-worktree null; exit 0; }
repository_root=$(CDPATH= cd "$repository_root" 2>/dev/null && pwd -P) || { emit blocked repository-root-unavailable null; exit 0; }
[ "$repository_root" = "$worktree" ] || { emit input-invalid worktree-root-mismatch null; exit 0; }

observe_commit_state || { emit blocked state-unavailable null; exit 0; }
pre_head_oid=$head_oid
block_if_unsafe
if [ "$has_staged_changes" = true ]; then emit_current blocked pre-staged-changes; fi

if ! stage_selected_paths; then
    observe_commit_state || { emit unknown-after-attempt stage-failed null; exit 0; }
    emit_current unknown-after-attempt stage-failed
fi
observe_commit_state || { emit unknown-after-attempt state-unavailable-after-stage null; exit 0; }
pre_head_oid=$head_oid
block_if_unsafe
if [ "$has_staged_changes" = false ]; then emit_current no-op no-selected-changes; fi

if git commit -F - >/dev/null 2>&1; then commit_status=0; else commit_status=$?; fi
observe_commit_state || { emit unknown-after-attempt postcondition-unavailable null; exit 0; }
if [ "$commit_status" -eq 0 ] && is_oid "$head_oid" && [ "$head_oid" != "$pre_head_oid" ] \
    && [ "$operation_state" = none ] && [ "$has_unmerged" = false ]; then
    commit_oid=$head_oid
    emit_current completed committed
fi
if [ "$commit_status" -ne 0 ]; then emit_current unknown-after-attempt commit-failed; fi
emit_current unknown-after-attempt commit-postcondition-failed
