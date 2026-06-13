#!/usr/bin/env bash
# terraform-apply.sh - apply ONLY the runtime/main tree, ONLY when it exactly
# matches origin/main with a clean working tree.
#
# Guards (any failure aborts before touching AWS):
#   1. target dir is the canonical runtime tree
#   2. checked-out branch is 'main'
#   3. local HEAD == origin/main (after fetch)
#   4. working tree is clean (no drift, no untracked files)
#   5. interactive confirmation (unless --auto-approve AND CC_ALLOW_AUTO=1)
#
# The applied commit id, operator, timestamp and result are logged for audit.
#
# Usage:
#   sudo -u tfexec ./terraform-apply.sh [tf-subdir] [--auto-approve]
#
# Example:
#   sudo -u tfexec ./terraform-apply.sh envs/prod
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

do_apply() {
    local subdir="$1" auto="$2"
    require_cmd terraform git
    require_dir "$CC_RUNTIME"

    local tf_dir="${CC_RUNTIME}/${subdir}"
    require_dir "$tf_dir"

    # --- Guard 2: branch must be main -------------------------------------
    local branch; branch="$(current_branch "$CC_RUNTIME")"
    [ "$branch" = "main" ] || die "runtime is on '${branch}', not 'main'; refusing to apply"

    # --- Guard 3: must equal origin/main ----------------------------------
    log_info "verifying runtime is in sync with origin/main"
    git -C "$CC_RUNTIME" fetch origin --prune
    local local_head remote_head
    local_head="$(git -C "$CC_RUNTIME" rev-parse HEAD)"
    remote_head="$(git -C "$CC_RUNTIME" rev-parse origin/main)"
    if [ "$local_head" != "$remote_head" ]; then
        die "runtime HEAD (${local_head}) != origin/main (${remote_head}); run sync-main.sh first"
    fi

    # --- Guard 4: clean working tree --------------------------------------
    assert_clean "$CC_RUNTIME"

    # --- Audit header ------------------------------------------------------
    local who stamp logfile
    who="$(id -un)${SUDO_USER:+ (via sudo from ${SUDO_USER})}"
    stamp="$(date +'%Y%m%d-%H%M%S')"
    logfile="${CC_LOGDIR}/apply-${local_head:0:12}-${stamp}.log"
    log_to_file "$logfile"
    log_info "APPLY commit=${local_head} dir=${tf_dir} operator=${who}"

    pushd "$tf_dir" >/dev/null
    trap 'popd >/dev/null || true' EXIT

    terraform init -input=false -reconfigure
    terraform validate
    terraform plan -input=false -lock-timeout=120s -out=runtime.tfplan

    if [ "$auto" -eq 1 ] && [ "${CC_ALLOW_AUTO:-0}" -eq 1 ]; then
        log_warn "auto-approve enabled (CC_ALLOW_AUTO=1)"
    else
        # Independent apply-time confirmation, separate from PR approval.
        local reply
        read -r -p "Apply commit ${local_head:0:12} to AWS? type 'apply' to proceed: " reply
        [ "$reply" = "apply" ] || die "apply not confirmed; aborting"
    fi

    terraform apply -input=false -lock-timeout=120s runtime.tfplan
    log_info "APPLY OK commit=${local_head} operator=${who}"
}

main() {
    local subdir="." auto=0 arg
    for arg in "$@"; do
        case "$arg" in
            --auto-approve) auto=1 ;;
            -*) die "unknown option: ${arg}" ;;
            *)  subdir="$arg" ;;
        esac
    done
    # Serialize applies against syncs and other applies on the runtime tree.
    with_lock "runtime" do_apply "$subdir" "$auto"
}

main "$@"
