#!/usr/bin/env bash
# setup.sh - one-time (idempotent) bootstrap of the /opt/codecommit tree.
#
# Creates the directory layout, mirror-clones the CodeCommit repo as a bare
# repository, lays down the runtime/main worktree, and fixes ownership and
# permissions so that developers (group: $CC_DEV_GROUP) can work safely while
# the runtime area stays protected.
#
# Re-running is safe: every step checks whether it has already been done.
#
# Usage:
#   sudo ./setup.sh <clone-url>
#
# Example (HTTPS-GRC, recommended for CodeCommit + IAM):
#   sudo ./setup.sh codecommit::ap-northeast-1://infra
#
# Example (raw HTTPS):
#   sudo ./setup.sh https://git-codecommit.ap-northeast-1.amazonaws.com/v1/repos/infra
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main() {
    [ "$#" -eq 1 ] || die "usage: $0 <clone-url>"
    local clone_url="$1"

    require_cmd git getent install
    log_info "bootstrapping CodeCommit ops tree under ${CC_ROOT}"

    # 1. Ensure the developer group exists (does not fail if already present).
    if ! getent group "$CC_DEV_GROUP" >/dev/null; then
        log_info "creating group ${CC_DEV_GROUP}"
        groupadd --system "$CC_DEV_GROUP"
    fi

    # 2. Directory skeleton.
    #    - root:root, mode 0755 for the top and runtime parent
    #    - worktrees/ is setgid + group-writable so each dev sub-tree inherits
    #      the shared group and a sane umask-independent group bit.
    install -d -o root -g root            -m 0755 "$CC_ROOT"
    install -d -o root -g root            -m 0755 "${CC_ROOT}/bare"
    install -d -o root -g root            -m 0755 "${CC_ROOT}/runtime"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_WORKTREES"
    install -d -o root -g root            -m 0755 "$CC_SCRIPTS"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_LOGDIR"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_LOCKDIR"

    # 3. Bare clone (idempotent).
    if [ -d "${CC_BARE}" ] && git -C "${CC_BARE}" rev-parse --is-bare-repository >/dev/null 2>&1; then
        log_info "bare repository already present: ${CC_BARE}"
    else
        log_info "cloning bare repository from ${clone_url}"
        git clone --bare "$clone_url" "$CC_BARE"
        # A plain --bare clone does NOT create refs/remotes/origin/*.
        # Configure the standard fetch refspec so that 'origin/main' resolves,
        # which the runtime sync and apply guards rely on.
        git -C "$CC_BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
        git -C "$CC_BARE" fetch origin --prune
    fi

    # 4. Mark shared repo paths as safe so git does not refuse cross-user access
    #    ("detected dubious ownership in repository").
    git config --system --replace-all safe.directory "$CC_BARE"     || true
    git config --system --add         safe.directory "$CC_RUNTIME"  || true
    git config --system --add         safe.directory "${CC_WORKTREES}/*" || true

    # 5. runtime/main worktree (idempotent).
    if [ -d "${CC_RUNTIME}/.git" ] || git -C "$CC_BARE" worktree list 2>/dev/null | grep -q -- "$CC_RUNTIME"; then
        log_info "runtime worktree already present: ${CC_RUNTIME}"
    else
        log_info "creating runtime worktree pinned to main: ${CC_RUNTIME}"
        # Create/refresh a local 'main' that tracks origin/main, then attach it.
        git -C "$CC_BARE" branch -f main origin/main
        git -C "$CC_BARE" worktree add "$CC_RUNTIME" main
    fi

    # 6. Lock the runtime area down: owned by root, group read-only.
    #    Developers must NEVER edit here directly; only sync-main.sh writes.
    chown -R root:root "${CC_ROOT}/runtime"
    chmod -R go-w      "${CC_ROOT}/runtime"

    # 7. Install the scripts themselves into the canonical location.
    if [ "$SCRIPT_DIR" != "$CC_SCRIPTS" ]; then
        log_info "installing scripts into ${CC_SCRIPTS}"
        install -o root -g root -m 0755 "${SCRIPT_DIR}"/*.sh "$CC_SCRIPTS"/
        # common.sh is sourced, not executed; 0644 is enough.
        install -o root -g root -m 0644 "${SCRIPT_DIR}/common.sh" "$CC_SCRIPTS/common.sh"
    fi

    log_info "setup complete."
    log_info "  bare repo : ${CC_BARE}"
    log_info "  runtime   : ${CC_RUNTIME} (branch: $(current_branch "$CC_RUNTIME"), HEAD: $(short_sha "$CC_RUNTIME"))"
    log_info "  worktrees : ${CC_WORKTREES} (group ${CC_DEV_GROUP}, setgid)"
}

main "$@"
