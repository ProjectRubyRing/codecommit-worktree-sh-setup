#!/usr/bin/env bash
# create-worktree.sh - cut a per-developer worktree for a feature branch.
#
# A new branch is always created from the latest origin/main so that work
# starts from the trusted baseline. The worktree lives under
#   $CC_WORKTREES/<user>/<branch-slug>
# and is owned by that user (group: $CC_DEV_GROUP).
#
# Usage:
#   ./create-worktree.sh <user> <branch>
#
# Example:
#   ./create-worktree.sh alice feature/add-vpc
#   -> /opt/codecommit/worktrees/alice/feature-add-vpc  (branch feature/add-vpc)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

create_worktree() {
    local user="$1" branch="$2"
    local slug user_dir wt_path
    slug="$(branch_to_slug "$branch")"
    user_dir="${CC_WORKTREES}/${user}"
    wt_path="${user_dir}/${slug}"

    require_cmd git install
    require_dir "$CC_BARE"

    log_info "refreshing remote refs"
    git -C "$CC_BARE" fetch origin --prune

    if [ -e "$wt_path" ]; then
        die "worktree path already exists: ${wt_path} (use delete-worktree.sh first)"
    fi

    # Per-user directory, setgid so files keep the shared group.
    install -d -o "$user" -g "$CC_DEV_GROUP" -m 2750 "$user_dir"

    if git -C "$CC_BARE" show-ref --verify --quiet "refs/heads/${branch}"; then
        # Branch already exists locally: attach a worktree to it (do NOT reset
        # it to main, the dev may have history we must not destroy).
        log_warn "local branch '${branch}' already exists; attaching existing branch"
        git -C "$CC_BARE" worktree add "$wt_path" "$branch"
    elif git -C "$CC_BARE" show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
        # Branch exists on the remote: track it.
        log_info "remote branch origin/${branch} exists; checking it out"
        git -C "$CC_BARE" worktree add --track -b "$branch" "$wt_path" "origin/${branch}"
    else
        # Brand new branch off the trusted baseline.
        log_info "creating new branch '${branch}' from origin/main"
        git -C "$CC_BARE" worktree add -b "$branch" "$wt_path" origin/main
    fi

    # Hand ownership of the working files to the developer.
    chown -R "$user":"$CC_DEV_GROUP" "$wt_path"

    log_info "worktree ready:"
    log_info "  path   : ${wt_path}"
    log_info "  branch : $(current_branch "$wt_path")"
    log_info "  base   : $(short_sha "$wt_path")"
    # stdout: emit the path so callers can `cd "$(create-worktree.sh ...)"`.
    printf '%s\n' "$wt_path"
}

main() {
    [ "$#" -eq 2 ] || die "usage: $0 <user> <branch>"
    local user="$1" branch="$2"
    validate_username "$user"
    validate_branch "$branch"
    with_lock "repo" create_worktree "$user" "$branch"
}

main "$@"
