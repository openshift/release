#!/bin/bash
#
# Offboards a repository from OpenShift CI by removing its configuration
# directories from ci-operator/config/, ci-operator/jobs/, and
# core-services/prow/02_config/.
#
# Usage: hack/offboard-repo.sh <org/repo> [<org/repo> ...]
#
# Use --dry-run to see what would be removed without deleting anything.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=false
REPOS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] <org/repo> [<org/repo> ...]" >&2
            exit 0
            ;;
        */*)
            REPOS+=("$arg")
            ;;
        *)
            echo "ERROR: Invalid argument: $arg (expected org/repo)" >&2
            exit 1
            ;;
    esac
done

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "ERROR: No repositories specified" >&2
    echo "Usage: $0 [--dry-run] <org/repo> [<org/repo> ...]" >&2
    exit 1
fi

CI_DIRS=("ci-operator/config" "ci-operator/jobs" "core-services/prow/02_config")

for repo in "${REPOS[@]}"; do
    org="${repo%%/*}"
    name="${repo#*/}"
    found=false

    for dir in "${CI_DIRS[@]}"; do
        target="${REPO_ROOT}/${dir}/${org}/${name}"
        if [[ -d "$target" ]]; then
            found=true
            if $DRY_RUN; then
                echo "[dry-run] Would remove: ${dir}/${org}/${name}"
            else
                echo "Removing: ${dir}/${org}/${name}"
                rm -rf "$target"
            fi
        fi
    done

    if ! $found; then
        echo "WARNING: No directories found for ${repo}" >&2
    fi
done
