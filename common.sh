#!/usr/bin/env bash
# common.sh - shared helpers for the CodeCommit operations scripts.
#
# This file is meant to be *sourced*, not executed:
#     source "$(dirname "$0")/common.sh"
#
# It deliberately does NOT call `set -euo pipefail` itself, because the
# calling script owns that decision. It only provides functions, constants,
# and small guards that every script reuses.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Layout constants (override via environment before sourcing if needed)
# ---------------------------------------------------------------------------
: "${CC_ROOT:=/opt/codecommit}"
: "${CC_BARE:=${CC_ROOT}/bare/infra.git}"
: "${CC_WORKTREES:=${CC_ROOT}/worktrees}"
: "${CC_RUNTIME:=${CC_ROOT}/runtime/main}"
: "${CC_SCRIPTS:=${CC_ROOT}/scripts}"
: "${CC_LOGDIR:=${CC_ROOT}/logs}"
: "${CC_LOCKDIR:=${CC_ROOT}/locks}"

# Linux group that owns developer-writable areas.
: "${CC_DEV_GROUP:=codecommit-dev}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# All log lines go to stderr so that stdout stays clean for capturable output
# (e.g. a script that prints a path or a commit id for another script to read).
_cc_ts() { date +'%Y-%m-%dT%H:%M:%S%z'; }

log_info()  { printf '%s [INFO]  %s\n'  "$(_cc_ts)" "$*" >&2; }
log_warn()  { printf '%s [WARN]  %s\n'  "$(_cc_ts)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n'  "$(_cc_ts)" "$*" >&2; }

# die <message...> : log an error and exit non-zero.
die() {
    log_error "$*"
    exit 1
}

# log_to_file <logfile> : mirror everything written to stdout+stderr into a
# logfile *as well as* the terminal, preserving exit codes via pipefail.
# Call this once near the top of a script after `set -euo pipefail`.
log_to_file() {
    local logfile="$1"
    mkdir -p "$(dirname "$logfile")"
    # process substitution + tee keeps console output AND appends to the file
    exec > >(tee -a "$logfile") 2>&1
}

# ---------------------------------------------------------------------------
# Pre-flight guards
# ---------------------------------------------------------------------------
# require_cmd <cmd> [cmd...] : abort unless every command is on PATH.
require_cmd() {
    local missing=0 c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            log_error "required command not found: ${c}"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "missing prerequisites; aborting"
}

# require_dir <dir> : abort unless the directory exists.
require_dir() {
    [ -d "$1" ] || die "expected directory does not exist: $1"
}

# ---------------------------------------------------------------------------
# Input validation (defends against path traversal / shell-meta injection)
# ---------------------------------------------------------------------------
# A valid Linux username we are willing to create a sub-tree for.
validate_username() {
    local u="$1"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || die "invalid username: '${u}' (allowed: ^[a-z_][a-z0-9_-]{0,31}$)"
}

# A safe git branch name. Rejects path traversal, leading dashes, spaces,
# and the characters git itself forbids. Intentionally stricter than git.
validate_branch() {
    local b="$1"
    case "$b" in
        ""|-*|*..*|*" "*|*"~"*|*"^"*|*":"*|*"?"*|*"*"*|*"["*|*"\\"*|*"@{"*)
            die "invalid branch name: '${b}'" ;;
    esac
    [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "invalid branch name: '${b}' (allowed chars: A-Za-z0-9._/-)"
    case "$b" in */) die "branch name must not end with '/': '${b}'" ;; esac
}

# Turn a branch name into a filesystem-safe directory slug (feature/x -> feature-x).
branch_to_slug() {
    printf '%s' "$1" | tr '/' '-'
}

# ---------------------------------------------------------------------------
# Locking (prevents concurrent runs from racing on the same repo/worktree)
# ---------------------------------------------------------------------------
# with_lock <lockname> <command...> : run command while holding an exclusive
# flock. Exits 1 if the lock cannot be taken within the timeout.
with_lock() {
    local name="$1"; shift
    local lockfile="${CC_LOCKDIR}/${name}.lock"
    mkdir -p "$CC_LOCKDIR"
    exec {lock_fd}>"$lockfile" || die "cannot open lock file: ${lockfile}"
    if ! flock -w "${CC_LOCK_TIMEOUT:-300}" "$lock_fd"; then
        die "could not acquire lock '${name}' within ${CC_LOCK_TIMEOUT:-300}s"
    fi
    "$@"
    local rc=$?
    flock -u "$lock_fd"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------
# git_in <dir> <git-args...> : run git with -C against a directory.
git_in() { git -C "$1" "${@:2}"; }

# current_branch <worktree> : print the checked-out branch name.
current_branch() { git -C "$1" rev-parse --abbrev-ref HEAD; }

# head_sha <worktree> : print the full HEAD commit id.
head_sha() { git -C "$1" rev-parse HEAD; }

# short_sha <worktree> : print the abbreviated HEAD commit id.
short_sha() { git -C "$1" rev-parse --short HEAD; }

# assert_clean <worktree> : abort if there are uncommitted or untracked changes.
assert_clean() {
    local wt="$1"
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        git -C "$wt" status --short >&2
        die "working tree is not clean: ${wt}"
    fi
}
