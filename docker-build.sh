#!/usr/bin/env bash
# docker-build.sh - build a container image from a Containerfile/Dockerfile.
#
# Engine-agnostic: prefers `podman` (the supported engine on RHEL 9) and falls
# back to `docker` if that is what is installed. The Dockerfile/Containerfile
# syntax is identical for both.
#
# Tagging policy:
#   - built from runtime/main  -> <image>:<commit-sha>  AND  <image>:latest
#   - built from a dev worktree-> <image>:dev-<user>-<branch>-<shortsha>
#
# Usage:
#   ./docker-build.sh <context-dir> <image-name> [-f <dockerfile>] [--push <registry>]
#
# Examples:
#   ./docker-build.sh /opt/codecommit/runtime/main myapp
#   ./docker-build.sh /opt/codecommit/worktrees/alice/feature-x myapp -f build/Dockerfile
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

detect_engine() {
    if command -v podman >/dev/null 2>&1; then printf 'podman\n'
    elif command -v docker >/dev/null 2>&1; then printf 'docker\n'
    else die "no container engine found (install podman)"
    fi
}

is_runtime() {
    case "$(realpath "$1")" in
        "$(realpath "$CC_RUNTIME")"*) return 0 ;;
        *) return 1 ;;
    esac
}

main() {
    local context="" image="" dockerfile="" push_registry=""
    local args=("$@")
    local i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            -f)     i=$((i+1)); dockerfile="${args[$i]}" ;;
            --push) i=$((i+1)); push_registry="${args[$i]}" ;;
            -*)     die "unknown option: ${args[$i]}" ;;
            *)
                if [ -z "$context" ]; then context="${args[$i]}"
                elif [ -z "$image" ]; then image="${args[$i]}"
                else die "too many positional arguments"
                fi ;;
        esac
        i=$((i+1))
    done
    [ -n "$context" ] && [ -n "$image" ] || die "usage: $0 <context-dir> <image-name> [-f dockerfile] [--push registry]"
    require_dir "$context"

    local engine; engine="$(detect_engine)"
    : "${dockerfile:=${context}/Dockerfile}"
    [ -f "$dockerfile" ] || dockerfile="${context}/Containerfile"
    [ -f "$dockerfile" ] || die "no Dockerfile/Containerfile at ${context}"

    local branch sha tag stamp logfile
    branch="$(current_branch "$context")"
    sha="$(short_sha "$context")"
    stamp="$(date +'%Y%m%d-%H%M%S')"

    if is_runtime "$context"; then
        [ "$branch" = "main" ] || die "runtime build must be on main (got ${branch})"
        assert_clean "$context"
        tag="${image}:${sha}"
        log_info "OFFICIAL build from runtime/main -> ${tag} (+ :latest)"
    else
        # Derive the owning user from the worktrees path layout.
        local user; user="$(realpath "$context" | sed -E "s#^$(realpath "$CC_WORKTREES")/([^/]+)/.*#\1#")"
        tag="${image}:dev-${user}-${branch//\//-}-${sha}"
        log_info "DEV build from ${context} -> ${tag}"
    fi

    logfile="${CC_LOGDIR}/build-${image}-${sha}-${stamp}.log"
    log_to_file "$logfile"
    log_info "engine=${engine} dockerfile=${dockerfile} commit=${sha}"

    "$engine" build -t "$tag" -f "$dockerfile" \
        --label "org.opencontainers.image.revision=$(head_sha "$context")" \
        --label "git.branch=${branch}" \
        "$context"

    if is_runtime "$context"; then
        "$engine" tag "$tag" "${image}:latest"
    fi

    if [ -n "$push_registry" ]; then
        # ECR example: authenticate first, then push.
        #   aws ecr get-login-password --region <r> | podman login --username AWS --password-stdin <registry>
        local remote="${push_registry}/${tag}"
        log_info "pushing ${remote}"
        "$engine" tag "$tag" "$remote"
        "$engine" push "$remote"
    fi

    log_info "build complete: ${tag}"
    printf '%s\n' "$tag"
}

main "$@"
