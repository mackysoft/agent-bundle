#!/bin/sh

# The branch-create Skill supplies a branch goal and base policy. This flow
# performs its preferred Git-state checks and branch-changing commands.

export GIT_OPTIONAL_LOCKS=0
export GIT_PAGER=cat
export PAGER=cat
export GIT_TERMINAL_PROMPT=0
export GIT_EXTERNAL_DIFF=

emit() {
  printf '{"outcome":"%s","reason":"%s"}\n' "$1" "$2"
}

is_oid() {
  case "$1" in
    ''|*[!0123456789abcdef]*) return 1 ;;
  esac

  case ${#1} in
    40|64) return 0 ;;
    *) return 1 ;;
  esac
}

physical_path() {
  [ -d "$1" ] || return 1
  (
    CDPATH= cd "$1" 2>/dev/null || exit 1
    pwd -P
  )
}

git_path_to_posix() {
  case "$1" in
    [A-Za-z]:/*)
      git_drive=${1%%:*}
      git_rest=${1#?:}
      git_drive=$(printf '%s' "$git_drive" | tr '[:upper:]' '[:lower:]') || return 1
      printf '/%s%s\n' "$git_drive" "$git_rest"
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

gitc() {
  git -C "$worktree" "$@" 2>/dev/null
}

validate_ref() {
  case "$1" in
    *'@{'*|*'^'*|*'~'*|*':'*|*'..'*) return 1 ;;
  esac
  gitc check-ref-format "$1" >/dev/null
}

parse_refs() {
  case "$branch_ref" in
    refs/heads/*) branch_short=${branch_ref#refs/heads/} ;;
    *) return 1 ;;
  esac
  case "$base_ref" in
    refs/remotes/*/*) base_tail=${base_ref#refs/remotes/} ;;
    *) return 1 ;;
  esac
  base_remote=${base_tail%%/*}
  base_short=${base_tail#*/}
  [ -n "$branch_short" ] && [ -n "$base_remote" ] && [ -n "$base_short" ] || return 1
  validate_ref "$branch_ref" && validate_ref "$base_ref" || return 1
  remote_branch_ref="refs/remotes/$base_remote/$branch_short"
  validate_ref "$remote_branch_ref"
}

git_path_exists() {
  case "$1" in
    /*|[A-Za-z]:/*) candidate_path=$1 ;;
    *) candidate_path="$worktree/$1" ;;
  esac
  [ -e "$candidate_path" ] && return 0
  normalized_path=$(git_path_to_posix "$candidate_path") || return 1
  [ -e "$normalized_path" ]
}

has_in_progress_operation() {
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-apply rebase-merge sequencer BISECT_LOG BISECT_START AM_HEAD; do
    marker_path=$(gitc rev-parse --git-path "$marker") || return 2
    if git_path_exists "$marker_path"; then
      return 0
    fi
  done
  return 1
}

observe_current() {
  current_head_oid=$(gitc rev-parse --verify -q HEAD) || current_head_oid=
  if [ -n "$current_head_oid" ] && ! is_oid "$current_head_oid"; then
    return 1
  fi

  current_head_ref=$(gitc symbolic-ref -q HEAD) || current_head_ref=
  gitc status --porcelain=v2 -z --untracked-files=normal >/dev/null || return 1
  change_bytes=$(gitc status --porcelain=v2 -z --untracked-files=normal | wc -c) || return 1
  change_bytes=$(printf '%s' "$change_bytes" | tr -d '[:space:]')
  case "$change_bytes" in
    ''|*[!0123456789]*) return 1 ;;
  esac
  if [ "$change_bytes" -gt 0 ]; then
    has_changes=true
  else
    has_changes=false
  fi

  gitc ls-files -u >/dev/null || return 1
  if gitc ls-files -u | IFS= read -r unused_line; then
    has_unmerged=true
  else
    has_unmerged=false
  fi

  has_in_progress_operation
  operation_rc=$?
  case "$operation_rc" in
    0) has_operation=true ;;
    1) has_operation=false ;;
    *) return 1 ;;
  esac
}

resolve_required_ref() {
  resolved_oid=$(gitc rev-list -1 "$1") || return 1
  is_oid "$resolved_oid"
}

resolve_optional_ref() {
  gitc show-ref --verify --quiet "$1"
  resolved_rc=$?
  if [ "$resolved_rc" -eq 0 ]; then
    resolved_oid=$(gitc rev-list -1 "$1") || return 2
    is_oid "$resolved_oid" || return 2
    return 0
  fi
  [ "$resolved_rc" -eq 1 ] || return 2
  resolved_oid=
  return 1
}

observe_local_branch() {
  if gitc show-ref --verify --quiet "$branch_ref"; then
    local_branch_exists=true
    local_branch_oid=$(gitc rev-list -1 "$branch_ref") || return 1
    is_oid "$local_branch_oid" || return 1
  else
    local_rc=$?
    [ "$local_rc" -eq 1 ] || return 1
    local_branch_exists=false
    local_branch_oid=
  fi

  if [ "$current_head_ref" = "$branch_ref" ]; then
    branch_is_current=true
  else
    branch_is_current=false
  fi

  gitc worktree list --porcelain >/dev/null || return 1
  if [ "$local_branch_exists" = true ] && [ "$branch_is_current" = false ] \
    && gitc worktree list --porcelain | grep -F -x "branch $branch_ref" >/dev/null; then
    branch_in_other_worktree=true
  else
    branch_in_other_worktree=false
  fi
}

read_branch_upstream() {
  upstream_ref=
  upstream_state=none
  branch_remote=$(gitc config --get "branch.$branch_short.remote") || branch_remote=
  branch_merge=$(gitc config --get "branch.$branch_short.merge") || branch_merge=

  if [ -z "$branch_remote" ] && [ -z "$branch_merge" ]; then
    return 0
  fi
  if [ -z "$branch_remote" ] || [ -z "$branch_merge" ]; then
    upstream_state=invalid
    return 0
  fi
  case "$branch_remote" in
    .|*' '*|*'\n'*|*'\r'*) upstream_state=invalid; return 0 ;;
  esac
  case "$branch_merge" in
    refs/heads/*) upstream_short=${branch_merge#refs/heads/} ;;
    *) upstream_state=invalid; return 0 ;;
  esac
  [ -n "$upstream_short" ] || { upstream_state=invalid; return 0; }
  upstream_ref="refs/remotes/$branch_remote/$upstream_short"
  if ! validate_ref "$upstream_ref"; then
    upstream_state=invalid
    upstream_ref=
    return 0
  fi
  upstream_state=configured
}

contains_current_head() {
  [ -n "$current_head_oid" ] || return 1
  gitc merge-base --is-ancestor "$current_head_oid" "$1" >/dev/null
}

emit_result() {
  emit "$1" "$2"
}

blocked() {
  emit_result blocked "$1"
  exit 0
}

unknown_after_attempt() {
  emit_result unknown-after-attempt "$1"
  exit 0
}

verify_postcondition() {
  observe_current || return 1
  [ "$current_head_ref" = "$branch_ref" ] || return 1
  [ -n "$current_head_oid" ] || return 1
  read_branch_upstream || return 1
  [ "$upstream_state" != invalid ] || return 1
  if [ -n "$expected_upstream_ref" ]; then
    [ "$upstream_state" = configured ] && [ "$upstream_ref" = "$expected_upstream_ref" ]
  else
    [ "$upstream_state" = none ]
  fi
}

ensure_ready_state() {
  observe_current || return 2
  observe_local_branch || return 2
  if [ "$has_operation" = true ]; then
    return 10
  fi
  if [ "$has_unmerged" = true ]; then
    return 11
  fi
  if [ "$branch_in_other_worktree" = true ]; then
    return 12
  fi
  if [ "$branch_is_current" = false ] && [ "$has_changes" = true ] && [ "$preserve_current" = false ]; then
    return 13
  fi
  if [ "$local_branch_exists" = true ]; then
    read_branch_upstream || return 2
    [ "$upstream_state" != invalid ] || return 14
    if [ "$upstream_state" = configured ] && [ "$upstream_ref" != "$remote_branch_ref" ]; then
      return 14
    fi
  fi
  return 0
}

mode=${1-}
[ "$#" -gt 0 ] && shift
worktree_input=
branch_ref=
base_ref=
preserve_current=false

if [ "$mode" != ensure ]; then
  emit input-invalid invalid-operation '{}'
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree)
      [ -z "$worktree_input" ] && [ "$#" -ge 2 ] || { emit input-invalid invalid-arguments '{}'; exit 0; }
      worktree_input=$2
      shift 2
      ;;
    --branch-ref)
      [ -z "$branch_ref" ] && [ "$#" -ge 2 ] || { emit input-invalid invalid-arguments '{}'; exit 0; }
      branch_ref=$2
      shift 2
      ;;
    --base-ref)
      [ -z "$base_ref" ] && [ "$#" -ge 2 ] || { emit input-invalid invalid-arguments '{}'; exit 0; }
      base_ref=$2
      shift 2
      ;;
    --preserve-current)
      [ "$preserve_current" = false ] || { emit input-invalid invalid-arguments '{}'; exit 0; }
      preserve_current=true
      shift
      ;;
    *)
      emit input-invalid invalid-arguments '{}'
      exit 0
      ;;
  esac
done

if [ -z "$worktree_input" ] || [ -z "$branch_ref" ] || [ -z "$base_ref" ]; then
  emit input-invalid invalid-arguments '{}'
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  emit runtime-unavailable git-not-found '{}'
  exit 0
fi

case "$worktree_input" in
  /*) ;;
  *) emit input-invalid worktree-must-be-absolute-posix-root '{}'; exit 0 ;;
esac
case "$worktree_input" in
  *'\\'*) emit input-invalid worktree-must-be-absolute-posix-root '{}'; exit 0 ;;
esac
worktree=$(physical_path "$worktree_input") || {
  emit input-invalid worktree-not-readable '{}'
  exit 0
}
if [ "$worktree" != "$worktree_input" ]; then
  emit input-invalid worktree-must-be-physical-root '{}'
  exit 0
fi

repo_root=$(gitc rev-parse --show-toplevel) || {
  emit blocked not-a-git-worktree '{}'
  exit 0
}
repo_root=$(physical_path "$repo_root") || {
  repo_root=$(git_path_to_posix "$repo_root") || {
    emit blocked not-a-git-worktree '{}'
    exit 0
  }
  repo_root=$(physical_path "$repo_root") || {
    emit blocked not-a-git-worktree '{}'
    exit 0
  }
}
if [ "$repo_root" != "$worktree" ]; then
  emit input-invalid worktree-must-be-physical-root '{}'
  exit 0
fi

parse_refs || {
  emit input-invalid invalid-ref '{}'
  exit 0
}

current_head_oid=
current_head_ref=
has_changes=false
has_unmerged=false
has_operation=false
local_branch_exists=false
local_branch_oid=
branch_is_current=false
branch_in_other_worktree=false
upstream_ref=
upstream_state=none
base_oid=
remote_branch_oid=
expected_upstream_ref=

# Block known unsafe states before fetching, so a blocked result has no remote-ref change.
ensure_ready_state
ready_rc=$?
case "$ready_rc" in
  0) ;;
  10) blocked operation-in-progress ;;
  11) blocked unmerged ;;
  12) blocked branch-in-other-worktree ;;
  13) blocked dirty-worktree-requires-preserve-current ;;
  14) blocked upstream-inconsistent ;;
  *) blocked state-unavailable ;;
esac

if ! gitc remote get-url "$base_remote" >/dev/null; then
  blocked base-remote-not-configured
fi

if ! gitc fetch "$base_remote" --prune >/dev/null; then
  unknown_after_attempt fetch-failed
fi

# Fetch may have taken time; this is the final state check immediately before
# selecting and performing a branch-changing operation.
ensure_ready_state
ready_rc=$?
case "$ready_rc" in
  0) ;;
  10) blocked operation-in-progress ;;
  11) blocked unmerged ;;
  12) blocked branch-in-other-worktree ;;
  13) blocked dirty-worktree-requires-preserve-current ;;
  14) blocked upstream-inconsistent ;;
  *) blocked state-unavailable ;;
esac

resolve_required_ref "$base_ref"
base_rc=$?
if [ "$base_rc" -ne 0 ]; then
  blocked base-ref-not-found
fi
base_oid=$resolved_oid

resolve_optional_ref "$remote_branch_ref"
remote_rc=$?
case "$remote_rc" in
  0) remote_branch_oid=$resolved_oid ;;
  1) remote_branch_oid= ;;
  *) blocked state-unavailable ;;
esac

if [ "$local_branch_exists" = true ]; then
  if [ -n "$remote_branch_oid" ]; then
    if [ "$upstream_state" = none ]; then
      expected_upstream_ref=$remote_branch_ref
      needs_upstream=true
    elif [ "$upstream_ref" = "$remote_branch_ref" ]; then
      expected_upstream_ref=$remote_branch_ref
      needs_upstream=false
    else
      blocked upstream-inconsistent
    fi
  elif [ "$upstream_state" = none ]; then
    expected_upstream_ref=
    needs_upstream=false
  else
    blocked upstream-inconsistent
  fi

  if [ "$branch_is_current" = true ]; then
    if [ "$needs_upstream" = false ]; then
      emit_result no-op already-attached
      exit 0
    fi
    if ! gitc branch --set-upstream-to="$remote_branch_ref" "$branch_short" >/dev/null; then
      unknown_after_attempt set-upstream-failed
    fi
    if ! verify_postcondition; then
      unknown_after_attempt postcondition-failed
    fi
    emit_result completed upstream-set
    exit 0
  fi

  if [ "$preserve_current" = true ]; then
    if [ -z "$current_head_oid" ]; then
      blocked preserve-current-requires-head
    fi
    if ! contains_current_head "$local_branch_oid"; then
      blocked preservation-not-contained
    fi
  fi

  if ! gitc switch "$branch_short" >/dev/null; then
    unknown_after_attempt switch-failed
  fi
  if [ "$needs_upstream" = true ]; then
    if ! gitc branch --set-upstream-to="$remote_branch_ref" "$branch_short" >/dev/null; then
      unknown_after_attempt set-upstream-failed
    fi
  fi
  if ! verify_postcondition; then
    unknown_after_attempt postcondition-failed
  fi
  if [ "$needs_upstream" = true ]; then
    emit_result completed reused-and-upstream-set
  else
    emit_result completed reused
  fi
  exit 0
fi

if [ -n "$remote_branch_oid" ]; then
  if [ "$preserve_current" = true ]; then
    if [ -z "$current_head_oid" ]; then
      blocked preserve-current-requires-head
    fi
    if ! contains_current_head "$remote_branch_oid"; then
      blocked preservation-not-contained
    fi
  fi
  expected_upstream_ref=$remote_branch_ref
  if ! gitc switch --track -c "$branch_short" "$remote_branch_ref" >/dev/null; then
    unknown_after_attempt track-failed
  fi
  if ! verify_postcondition; then
    unknown_after_attempt postcondition-failed
  fi
  emit_result completed tracked
  exit 0
fi

if [ "$preserve_current" = true ]; then
  if [ -z "$current_head_oid" ]; then
    blocked preserve-current-requires-head
  fi
  start_oid=$current_head_oid
else
  start_oid=$base_oid
fi
expected_upstream_ref=
if ! gitc switch -c "$branch_short" "$start_oid" >/dev/null; then
  unknown_after_attempt create-failed
fi
if ! verify_postcondition; then
  unknown_after_attempt postcondition-failed
fi
emit_result completed created
