#!/usr/bin/env bash
# terraform-plan.sh - fmt + validate + plan inside a development worktree.
#
# This is the "safe" Terraform entrypoint developers use while iterating.
# It NEVER applies. It writes a binary plan file and a human-readable log so a
# reviewer can see exactly what was proposed.
#
# Usage:
#   ./terraform-plan.sh <worktree-dir> [tf-dir-relative-to-worktree]
#
# Example:
#   ./terraform-plan.sh /opt/codecommit/worktrees/alice/feature-add-vpc envs/dev
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main() {
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: $0 <worktree-dir> [tf-subdir]"
    local wt="$1" subdir="${2:-.}"
    require_cmd terraform git
    require_dir "$wt"

    # Guard: refuse to run plan against the protected runtime tree; plan there
    # is harmless but we want developers to stay in their own worktrees.
    case "$(realpath "$wt")" in
        "$(realpath "$CC_RUNTIME")"*) die "use terraform-apply.sh for the runtime tree, not plan here" ;;
    esac

    local tf_dir="${wt}/${subdir}"
    require_dir "$tf_dir"

    local branch sha stamp logfile planfile
    branch="$(current_branch "$wt")"
    sha="$(short_sha "$wt")"
    stamp="$(date +'%Y%m%d-%H%M%S')"
    logfile="${CC_LOGDIR}/plan-${branch//\//-}-${sha}-${stamp}.log"
    planfile="${tf_dir}/plan-${sha}-${stamp}.tfplan"
    log_to_file "$logfile"

    log_info "terraform plan in ${tf_dir} (branch ${branch}, ${sha})"

    pushd "$tf_dir" >/dev/null
    trap 'popd >/dev/null || true' EXIT

    terraform fmt -check -recursive || die "terraform fmt found unformatted files (run: terraform fmt -recursive)"
    # -input=false avoids hanging on a prompt under cron/CI; backend stays remote.
    terraform init -input=false -reconfigure
    terraform validate
    # Save a binary plan so apply (later, on main) could reuse an identical plan
    # if desired. Plan files may contain sensitive values: they live only inside
    # the developer's worktree and are wiped by git clean in runtime.
    terraform plan -input=false -lock-timeout=120s -out="$planfile"

    log_info "plan saved: ${planfile}"
    log_info "log saved : ${logfile}"
}

main "$@"
