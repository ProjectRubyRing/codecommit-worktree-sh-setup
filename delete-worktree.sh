#!/usr/bin/env bash
# delete-worktree.sh - tear down a finished worktree (and optionally branches).
#
# By default this removes only the working directory and the local branch.
# The remote branch is left intact unless --remote is given, because deleting
# a remote branch may break an open Pull Request.
#
# Usage:
#   ./delete-worktree.sh <user> <branch> [--remote] [--force] [--yes]
#
#   --remote   also delete the branch on origin (CodeCommit)
#   --force    pass --force to `git worktree remove` (discards local changes)
#   --yes      skip the interactive confirmation prompt
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

confirm() {
    local prompt="$1"
    if [ "${ASSUME_YES:-0}" -eq 1 ]; then
        return 0
    fi
    local reply
    read -r -p "${prompt} [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

delete_worktree() {
    local user="$1" branch="$2"
    local slug wt_path
    slug="$(branch_to_slug "$branch")"
    wt_path="${CC_WORKTREES}/${user}/${slug}"

    require_dir "$CC_BARE"

    if [ ! -e "$wt_path" ]; then
        log_warn "worktree path not found (already gone?): ${wt_path}"
    else
        # Refuse to remove a dirty worktree unless --force was given.
        if [ "${FORCE:-0}" -ne 1 ] && [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
            git -C "$wt_path" status --short >&2
            die "worktree has uncommitted changes; commit/push them or re-run with --force"
        fi
        confirm "Remove worktree '${wt_path}' (branch '${branch}')?" || die "aborted by user"
        log_info "removing worktree ${wt_path}"
        if [ "${FORCE:-0}" -eq 1 ]; then
            git -C "$CC_BARE" worktree remove --force "$wt_path"
        else
            git -C "$CC_BARE" worktree remove "$wt_path"
        fi
    fi

    git -C "$CC_BARE" worktree prune

    # Delete the local branch (use -D; the branch may not be merged into the
    # bare repo's local main even though it is merged on the remote).
    if git -C "$CC_BARE" show-ref --verify --quiet "refs/heads/${branch}"; then
        log_info "deleting local branch ${branch}"
        git -C "$CC_BARE" branch -D "$branch"
    fi

    if [ "${DELETE_REMOTE:-0}" -eq 1 ]; then
        confirm "Also delete REMOTE branch origin/${branch}? This can break an open PR." \
            || die "remote deletion aborted by user"
        log_info "deleting remote branch origin/${branch}"
        git -C "$CC_BARE" push origin --delete "$branch"
    fi

    log_info "delete complete for ${user}/${branch}"
}

main() {
    local user="" branch="" arg
    DELETE_REMOTE=0; FORCE=0; ASSUME_YES=0
    for arg in "$@"; do
        case "$arg" in
            --remote) DELETE_REMOTE=1 ;;
            --force)  FORCE=1 ;;
            --yes)    ASSUME_YES=1 ;;
            -*)       die "unknown option: ${arg}" ;;
            *)
                if [ -z "$user" ]; then user="$arg"
                elif [ -z "$branch" ]; then branch="$arg"
                else die "too many positional arguments"
                fi ;;
        esac
    done
    [ -n "$user" ] && [ -n "$branch" ] || die "usage: $0 <user> <branch> [--remote] [--force] [--yes]"
    validate_username "$user"
    validate_branch "$branch"
    with_lock "repo" delete_worktree "$user" "$branch"
}

main "$@"
