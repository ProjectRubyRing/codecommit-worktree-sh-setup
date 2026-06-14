#!/usr/bin/env bash
# initial-commit.sh - seed an EMPTY CodeCommit repo with a first commit on main.
#
# CodeCommit creates repositories with no branches. Until something is pushed,
# 'main' does not exist and worktrees cannot be created. This script pushes a
# minimal, sensible scaffold (README, .gitignore, envs/ skeleton) onto main.
#
# It is idempotent: if origin already has a 'main' branch, it does nothing.
#
# Auth uses whatever the current identity provides (EC2 instance role via
# git-remote-codecommit is expected). The pushing identity needs codecommit:GitPush.
#
# Usage:
#   ./initial-commit.sh <clone-url>
#
# Optional environment overrides:
#   CC_COMMIT_NAME   (default: ops)
#   CC_COMMIT_EMAIL  (default: ops@example.com)
#   CC_DEFAULT_BRANCH(default: main)
#
# Example:
#   ./initial-commit.sh codecommit::ap-northeast-1://infra
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

: "${CC_COMMIT_NAME:=ops}"
: "${CC_COMMIT_EMAIL:=ops@example.com}"
: "${CC_DEFAULT_BRANCH:=main}"

scaffold() {
    local dir="$1"
    cat > "${dir}/README.md" <<'EOF'
# infra

AWS の Terraform / Dockerfile を CodeCommit で管理するリポジトリ。

- 本番に出るコードは `main` にだけ存在する（直接 push 禁止 / PR 承認必須）。
- 環境はディレクトリで分離する（`envs/dev`, `envs/prod`）。
- 運用管理サーバーは `main` にマージ済みのコードのみを実行する。
EOF

    cat > "${dir}/.gitignore" <<'EOF'
# Terraform
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
*.tfplan
crash.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraformrc
terraform.rc

# secrets / local
*.auto.tfvars
*.tfvars
!*.tfvars.example
.env
EOF

    mkdir -p "${dir}/envs/dev" "${dir}/envs/prod" "${dir}/modules"
    printf '# place dev-environment Terraform here\n'  > "${dir}/envs/dev/.gitkeep"
    printf '# place prod-environment Terraform here\n' > "${dir}/envs/prod/.gitkeep"
    printf '# place reusable modules here\n'           > "${dir}/modules/.gitkeep"
}

main() {
    [ "$#" -eq 1 ] || die "usage: $0 <clone-url>"
    local clone_url="$1"
    require_cmd git

    # Idempotency: if main already exists on the remote, do nothing.
    if git ls-remote --heads "$clone_url" "$CC_DEFAULT_BRANCH" \
         | grep -q "refs/heads/${CC_DEFAULT_BRANCH}$"; then
        log_info "origin already has '${CC_DEFAULT_BRANCH}'; nothing to do"
        return 0
    fi

    # Refuse to overwrite a non-empty repo that simply lacks 'main'
    # (e.g. default branch is 'master') - that needs a human decision.
    local other_heads
    other_heads="$(git ls-remote --heads "$clone_url" | sed 's#.*refs/heads/##' || true)"
    if [ -n "$other_heads" ]; then
        log_error "remote is not empty but has no '${CC_DEFAULT_BRANCH}' branch."
        log_error "existing branches: $(printf '%s ' "$other_heads")"
        die "refusing to auto-seed; create '${CC_DEFAULT_BRANCH}' from an existing branch manually"
    fi

    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand tmp now so the trap removes the right dir
    trap "rm -rf '${tmp}'" EXIT

    log_info "seeding initial commit on '${CC_DEFAULT_BRANCH}'"
    git -C "$tmp" init -q -b "$CC_DEFAULT_BRANCH"
    git -C "$tmp" remote add origin "$clone_url"
    scaffold "$tmp"
    git -C "$tmp" add -A
    git -C "$tmp" \
        -c user.name="$CC_COMMIT_NAME" \
        -c user.email="$CC_COMMIT_EMAIL" \
        commit -q -m "Initial commit: scaffold infra repository"
    git -C "$tmp" push -u origin "$CC_DEFAULT_BRANCH"

    log_info "pushed '${CC_DEFAULT_BRANCH}' to ${clone_url}"
}

main "$@"
