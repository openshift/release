#!/bin/bash
#
# Offboards a repository from OpenShift CI by removing its configuration
# directories from ci-operator/config/, ci-operator/jobs/, and
# core-services/prow/02_config/ and pruning the per-repository entries in
# shared configuration files:
#   - core-services/sanitize-prow-jobs/_config.yaml
#   - core-services/prow/02_config/_config.yaml (tide context options)
#   - clusters/app.ci/publicize/_config.yaml
#
# Usage: hack/offboard-repo.sh <org/repo> [<org/repo> ...]
#
# Use --dry-run to see what would be removed without changing anything.

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
JOBS_DIR="${REPO_ROOT}/ci-operator/jobs"
SANITIZE_CONFIG="${REPO_ROOT}/core-services/sanitize-prow-jobs/_config.yaml"
PROW_CONFIG="${REPO_ROOT}/core-services/prow/02_config/_config.yaml"
PUBLICIZE_CONFIG="${REPO_ROOT}/clusters/app.ci/publicize/_config.yaml"

# Present job files, excluding the repositories being offboarded so that
# --dry-run and repeated runs behave the same as the initial run.
present_job_files() {
    local -a exclude=()
    local repo
    for repo in "${REPOS[@]}"; do
        exclude+=(-not -path "${JOBS_DIR}/${repo}/*")
    done
    if [[ -d "$JOBS_DIR" ]]; then
        find "$JOBS_DIR" -type f -name '*.yaml' "${exclude[@]}" -printf '%f\n' | sort -u
    fi
}

# Removes entries from the filenames lists of the sanitize-prow-jobs config
# that belong to the offboarded repository. Entries are matched by the
# flattened org/repo prefix; the check against present job files protects
# repositories whose flattened name extends another repository's name.
prune_sanitize_entries() {
    local prefix="$1" present_file="$2"
    [[ -f "$SANITIZE_CONFIG" ]] || return 0

    local tmp
    tmp="$(mktemp)"
    awk -v prefix="$prefix" -v present_file="$present_file" -v dry_run="$DRY_RUN" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        BEGIN {
            while ((getline name < present_file) > 0) {
                present[name] = 1
            }
            close(present_file)
        }
        {
            line = $0
            if (line ~ /^[ ]*filenames:[ ]*$/) {
                in_filenames = 1
                filenames_indent = indent(line)
                print line
                next
            }
            if (in_filenames) {
                if (line ~ /^[ ]*$/) {
                    print line
                    next
                }
                if (line ~ /^[ ]*- / && indent(line) == filenames_indent) {
                    name = line
                    sub(/^[ ]*- /, "", name)
                    if (index(name, prefix) == 1 && !(name in present)) {
                        if (dry_run == "true") {
                            printf "[dry-run] Would remove sanitize entry: %s\n", name > "/dev/stderr"
                        }
                        next
                    }
                    print line
                    next
                }
                in_filenames = 0
            }
            print line
        }
    ' "$SANITIZE_CONFIG" > "$tmp"

    if [[ "$DRY_RUN" == true ]]; then
        rm -f "$tmp"
    else
        cat "$tmp" > "$SANITIZE_CONFIG"
        rm -f "$tmp"
    fi
}

# Removes the repository entry below tide.context_options.orgs.<org>.repos.
prune_tide_context_options() {
    local org="$1" name="$2"
    [[ -f "$PROW_CONFIG" ]] || return 0

    local tmp
    tmp="$(mktemp)"
    awk -v org="$org" -v repo="$name" -v dry_run="$DRY_RUN" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        BEGIN { depth = 0; skipping = 0; skip_indent = -1 }
        {
            line = $0
            if (line ~ /^[ ]*$/) {
                print line
                next
            }
            current_indent = indent(line)

            if (skipping) {
                if (current_indent > skip_indent) {
                    next
                }
                skipping = 0
            }

            while (depth > 0 && stack_indent[depth] >= current_indent) {
                depth--
            }

            key = line
            sub(/^[ ]*/, "", key)
            sub(/:.*/, "", key)

            if (depth == 5 &&
                stack_key[1] == "tide" &&
                stack_key[2] == "context_options" &&
                stack_key[3] == "orgs" &&
                stack_key[4] == org &&
                stack_key[5] == "repos" &&
                key == repo &&
                line ~ /^[ ]*[^# ][^:]*:[ ]*$/) {
                if (dry_run == "true") {
                    printf "[dry-run] Would remove tide context_options entry: %s/%s\n", org, repo > "/dev/stderr"
                }
                skipping = 1
                skip_indent = current_indent
                next
            }

            print line

            if (line !~ /^[ ]*- / && line ~ /^[ ]*[^# ][^:]*:[ ]*$/) {
                depth++
                stack_indent[depth] = current_indent
                stack_key[depth] = key
            }
        }
    ' "$PROW_CONFIG" > "$tmp"

    if [[ "$DRY_RUN" == true ]]; then
        rm -f "$tmp"
    else
        cat "$tmp" > "$PROW_CONFIG"
        rm -f "$tmp"
    fi
}

# Removes a mapping whose target is the offboarded repository.
prune_publicize_mapping() {
    local target="$1"
    [[ -f "$PUBLICIZE_CONFIG" ]] || return 0

    local tmp
    tmp="$(mktemp)"
    awk -v target="$target" -v dry_run="$DRY_RUN" '
        {
            line = $0
            if (line ~ /^[ ]*[^:#]+:[ ]*[^ ]/) {
                value = line
                sub(/^[ ]*[^:#]+:[ ]*/, "", value)
                sub(/[ ]+$/, "", value)
                if (value == target) {
                    if (dry_run == "true") {
                        printf "[dry-run] Would remove publicize mapping: %s\n", target > "/dev/stderr"
                    }
                    next
                }
            }
            print line
        }
    ' "$PUBLICIZE_CONFIG" > "$tmp"

    if [[ "$DRY_RUN" == true ]]; then
        rm -f "$tmp"
    else
        cat "$tmp" > "$PUBLICIZE_CONFIG"
        rm -f "$tmp"
    fi
}

present_file="$(mktemp)"
present_job_files > "$present_file"

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

    prune_sanitize_entries "${repo//\//-}-" "$present_file"
    prune_tide_context_options "$org" "$name"
    prune_publicize_mapping "$repo"
done

rm -f "$present_file"
