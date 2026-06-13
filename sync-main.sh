#!/usr/bin/env bash
# sync-main.sh - force the runtime/main worktree to exactly match origin/main.
#
# This is the ONLY thing allowed to write into the runtime tree. It is safe to
# run from cron or a systemd timer: flock prevents overlapping runs, and the
# before/after commit ids are written to a log for audit.
#
# Behaviour:
#   git fetch origin --prune
#   git reset --hard origin/main      <- discards any drift in runtime/main
#   git clean -fdx                     <- removes untracked files (incl. .terraform)
#
# Usage:
#   ./sync-main.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

do_sync() {
    require_dir "$CC_RUNTIME"
    local logfile="${CC_LOGDIR}/sync-main.log"
    log_to_file "$logfile"

    local branch before after
    branch="$(current_branch "$CC_RUNTIME")"
    if [ "$branch" != "main" ]; then
        die "runtime worktree is on '${branch}', expected 'main'; refusing to sync"
    fi

    before="$(head_sha "$CC_RUNTIME")"
    log_info "sync start: runtime at ${before}"

    git -C "$CC_RUNTIME" fetch origin --prune
    git -C "$CC_RUNTIME" reset --hard origin/main
    # -x also removes ignored files such as local .terraform/ caches so that the
    # runtime tree is byte-for-byte what is in origin/main. This is intentional
    # and destructive: nothing of value must ever live only in runtime/main.
    git -C "$CC_RUNTIME" clean -fdx

    after="$(head_sha "$CC_RUNTIME")"
    if [ "$before" = "$after" ]; then
        log_info "sync done: already up to date at ${after}"
    else
        log_info "sync done: ${before} -> ${after}"
    fi
}

main() {
    [ "$#" -eq 0 ] || die "usage: $0 (no arguments)"
    # Non-blocking-ish: short timeout so a stuck timer instance does not pile up.
    CC_LOCK_TIMEOUT="${CC_LOCK_TIMEOUT:-60}" with_lock "runtime" do_sync
}

main "$@"
