#!/usr/bin/env bash
# setup.sh - one-time (idempotent) bootstrap of the /opt/codecommit tree.
#
# Creates the directory layout, mirror-clones the CodeCommit repo as a bare
# repository, lays down the runtime/main worktree, and fixes ownership and
# permissions so that developers (group: $CC_DEV_GROUP) can work safely while
# the runtime area stays protected.
#
# Re-running is safe: every step checks whether it has already been done, and
# the bare repo is ALWAYS re-fetched so a freshly-pushed main is picked up.
#
# Usage:
#   sudo ./setup.sh <clone-url> [--bootstrap]
#
#   --bootstrap   if the remote has no 'main' branch yet (brand-new empty
#                 CodeCommit repo), seed it via initial-commit.sh before
#                 creating the runtime worktree.
#
# Example (HTTPS-GRC, recommended for CodeCommit + IAM):
#   sudo ./setup.sh codecommit::ap-northeast-1://infra --bootstrap
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# remote_has_main: true if refs/remotes/origin/main exists locally (after fetch).
remote_has_main() {
    git -C "$CC_BARE" show-ref --verify --quiet refs/remotes/origin/main
}

main() {
    local clone_url="" bootstrap=0 arg
    for arg in "$@"; do
        case "$arg" in
            --bootstrap) bootstrap=1 ;;
            -*) die "unknown option: ${arg}" ;;
            *)
                if [ -z "$clone_url" ]; then clone_url="$arg"
                else die "too many arguments"
                fi ;;
        esac
    done
    [ -n "$clone_url" ] || die "usage: $0 <clone-url> [--bootstrap]"

    require_cmd git getent install
    log_info "bootstrapping CodeCommit ops tree under ${CC_ROOT}"

    # 1. Ensure the developer group exists (does not fail if already present).
    if ! getent group "$CC_DEV_GROUP" >/dev/null; then
        log_info "creating group ${CC_DEV_GROUP}"
        groupadd --system "$CC_DEV_GROUP"
    fi

    # 2. Directory skeleton.
    install -d -o root -g root            -m 0755 "$CC_ROOT"
    install -d -o root -g root            -m 0755 "${CC_ROOT}/bare"
    install -d -o root -g root            -m 0755 "${CC_ROOT}/runtime"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_WORKTREES"
    install -d -o root -g root            -m 0755 "$CC_SCRIPTS"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_LOGDIR"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_LOCKDIR"

    # 3. Bare clone (idempotent) - then ALWAYS configure refspec and fetch.
    if [ -d "${CC_BARE}" ] && git -C "${CC_BARE}" rev-parse --is-bare-repository >/dev/null 2>&1; then
        log_info "bare repository already present: ${CC_BARE}"
    else
        log_info "cloning bare repository from ${clone_url}"
        # A brand-new empty remote clones fine (just warns 'empty repository').
        git clone --bare "$clone_url" "$CC_BARE"
    fi
    # A plain --bare clone does NOT create refs/remotes/origin/*; set the
    # standard fetch refspec every run (idempotent) so 'origin/main' resolves.
    git -C "$CC_BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    log_info "fetching from origin"
    git -C "$CC_BARE" fetch origin --prune

    # 4. Mark shared repo paths as safe (cross-user access).
    git config --system --replace-all safe.directory "$CC_BARE"     || true
    git config --system --add         safe.directory "$CC_RUNTIME"  || true
    git config --system --add         safe.directory "${CC_WORKTREES}/*" || true

    # 5. Ensure origin/main exists BEFORE trying to build the runtime worktree.
    if ! remote_has_main; then
        local heads
        heads="$(git -C "$CC_BARE" for-each-ref --format='%(refname:short)' refs/remotes/origin/ || true)"
        if [ "$bootstrap" -eq 1 ]; then
            log_warn "no 'main' on origin; bootstrapping via initial-commit.sh"
            "${SCRIPT_DIR}/initial-commit.sh" "$clone_url"
            git -C "$CC_BARE" fetch origin --prune
            remote_has_main || die "bootstrap ran but 'main' still missing on origin"
        else
            log_error "the remote has no 'main' branch, so runtime/main cannot be created."
            if [ -n "$heads" ]; then
                log_error "remote branches present: $(printf '%s ' "$heads")"
                log_error "if the default branch is not 'main', push it as main first."
            else
                log_error "the remote appears EMPTY (no branches yet)."
            fi
            log_error "fix: seed an initial commit, then re-run setup. Either:"
            log_error "   ${SCRIPT_DIR}/initial-commit.sh ${clone_url}"
            log_error "or re-run: sudo $0 ${clone_url} --bootstrap"
            die "aborting: 'main' not found on origin"
        fi
    fi

    # 6. runtime/main worktree (idempotent).
    if [ -d "${CC_RUNTIME}/.git" ] || git -C "$CC_BARE" worktree list 2>/dev/null | grep -q -- "$CC_RUNTIME"; then
        log_info "runtime worktree already present: ${CC_RUNTIME}"
    else
        log_info "creating runtime worktree pinned to main: ${CC_RUNTIME}"
        git -C "$CC_BARE" branch -f main origin/main
        git -C "$CC_BARE" worktree add "$CC_RUNTIME" main
    fi

    # 7. Lock the runtime area down: owned by root, group read-only.
    chown -R root:root "${CC_ROOT}/runtime"
    chmod -R go-w      "${CC_ROOT}/runtime"

    # 8. Install the scripts into the canonical location.
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
