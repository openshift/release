#!/usr/bin/env bash
#
# prow-fetch.sh - Fetch artifacts and data from Prow and GCS
#
# Wrapper for curling Prow job data and artifacts to avoid repeated permission prompts
#
# Usage:
#   prow-fetch.sh <URL>
#   prow-fetch.sh build-log <PR_NUM> <JOB_ID> <STEP_NAME>
#   prow-fetch.sh finished <PR_NUM> <JOB_ID>
#   prow-fetch.sh pr-checks <PR_NUM> [PATTERN]
#
# Examples:
#   # Fetch full URL (easiest - copy from Prow UI or monitor output)
#   prow-fetch.sh https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/79244/rehearse-.../2056429033742143488/finished.json
#
#   # Fetch build log for a step (auto-detects job name and paths)
#   prow-fetch.sh build-log 79244 2056429033742143488 install-trustee-operator
#
#   # Fetch finished.json
#   prow-fetch.sh finished 79244 2056429033742143488
#
#   # Get PR check status (shows job IDs)
#   prow-fetch.sh pr-checks 79244 azure-ipi-coco
#

set -euo pipefail

# Base URLs
PROW_BASE="https://prow.ci.openshift.org"
GCS_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"

function show_usage() {
    cat >&2 << 'EOF'
Usage: prow-fetch.sh <command> [args...]

Commands:
  <URL>                         Fetch any Prow or GCS URL directly (EASIEST)
  build-log <PR> <JOB_ID> <STEP> Fetch build log for a step
  finished <PR> <JOB_ID>        Fetch finished.json for a job
  started <PR> <JOB_ID>         Fetch started.json for a job
  clone-records <PR> <JOB_ID>   Fetch clone-records.json
  pr-checks <PR> [PATTERN]      Get PR check status (via gh)

Environment Variables:
  PROW_FETCH_QUIET     Set to 1 to suppress stderr messages (only output data)
  PROW_FETCH_HEADERS   Set to 1 to include HTTP headers in output

Notes:
  - EASIEST: Just copy/paste full URLs from Prow or GCS
  - Requires 'gh' CLI for job name lookup in build-log/finished/started commands
  - Job IDs come from 'gh pr checks' or monitor scripts

Examples:
  # Direct URL fetch (copy from Prow UI) - RECOMMENDED
  prow-fetch.sh https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/...

  # Fetch build log (auto-looks up job name from job ID)
  prow-fetch.sh build-log 79244 2056429033742143488 install-trustee-operator

  # Fetch job status
  prow-fetch.sh finished 79244 2056429033742143488 | jq -r '.result'

  # Get PR checks (find job IDs)
  prow-fetch.sh pr-checks 79244 azure-ipi-coco
EOF
}

function log_info() {
    if [[ "${PROW_FETCH_QUIET:-0}" != "1" ]]; then
        echo "[prow-fetch] $*" >&2
    fi
}

function log_error() {
    echo "[prow-fetch] ERROR: $*" >&2
}

function fetch_url() {
    local url="$1"
    local curl_opts=(-sS)

    if [[ "${PROW_FETCH_HEADERS:-0}" == "1" ]]; then
        curl_opts+=(-i)
    fi

    log_info "Fetching: ${url}"
    curl "${curl_opts[@]}" "${url}"
}

function get_job_name() {
    local pr="$1"
    local job_id="$2"

    # Try to get job name from gh pr checks (most reliable)
    local job_name
    job_name=$(gh pr checks "${pr}" --repo openshift/release 2>/dev/null | grep "${job_id}" | awk '{print $1}' | sed 's@ci/rehearse/@@' || echo "")

    if [[ -n "${job_name}" ]]; then
        echo "${job_name}"
        return 0
    fi

    # Fallback: Try to list GCS directory to find the job name
    # Format: /pr-logs/pull/openshift_release/{PR}/
    local gcs_list_url="${GCS_BASE}/pr-logs/pull/openshift_release/${pr}/?delimiter=/"
    job_name=$(curl -sS "${gcs_list_url}" 2>/dev/null | grep -oP "href=\"[^\"]*${job_id}[^\"]*\"" | grep -oP 'rehearse-[^/]+' | head -1 || echo "")

    if [[ -n "${job_name}" ]]; then
        log_info "Found job name from GCS listing: ${job_name}"
        echo "${job_name}"
        return 0
    fi

    # Last resort: Assume job name pattern based on PR
    log_error "Could not determine job name for job ID ${job_id}"
    log_error "Tried: gh pr checks and GCS listing"
    return 1
}

function pr_checks() {
    local pr="$1"
    local pattern="${2:-rehearse}"

    log_info "Getting PR checks for #${pr}"
    gh pr checks "${pr}" --repo openshift/release 2>/dev/null | grep "${pattern}" || true
}

function fetch_build_log() {
    local pr="$1"
    local job_id="$2"
    local step_name="$3"

    # Get job name
    local job_name
    job_name=$(get_job_name "${pr}" "${job_id}")

    # Build log is typically at: artifacts/{CLUSTER}/{STEP_NAME}/build-log.txt
    # Extract cluster from job name (e.g., "rehearse-79244-periodic-ci-...-azure-ipi-coco" -> "azure-ipi-coco")
    local cluster_name=""
    if [[ "${job_name}" =~ -([a-z]+-[a-z]+-[a-z]+)$ ]]; then
        cluster_name="${BASH_REMATCH[1]}"
    elif [[ "${job_name}" =~ -([a-z]+-[a-z]+)$ ]]; then
        cluster_name="${BASH_REMATCH[1]}"
    else
        log_error "Could not extract cluster name from job: ${job_name}"
        log_info "Trying common artifact path..."
        cluster_name="*"
    fi

    # Try with the full step registry name if step doesn't have prefix
    local step_paths=(
        "${cluster_name}/${step_name}/build-log.txt"
        "${cluster_name}/sandboxed-containers-operator-${step_name}/build-log.txt"
        "${cluster_name}/*${step_name}*/build-log.txt"
    )

    local artifact_url_base="${GCS_BASE}/pr-logs/pull/openshift_release/${pr}/${job_name}/${job_id}/artifacts"

    for step_path in "${step_paths[@]}"; do
        local artifact_url="${artifact_url_base}/${step_path}"
        log_info "Trying: ${artifact_url}"

        if curl -sS -f "${artifact_url}" 2>/dev/null; then
            return 0
        fi
    done

    log_error "Could not fetch build log for step '${step_name}'"
    log_error "Tried paths: ${step_paths[*]}"
    return 1
}

function fetch_finished() {
    local pr="$1"
    local job_id="$2"

    local job_name
    job_name=$(get_job_name "${pr}" "${job_id}")

    local url="${GCS_BASE}/pr-logs/pull/openshift_release/${pr}/${job_name}/${job_id}/finished.json"
    fetch_url "${url}"
}

function fetch_started() {
    local pr="$1"
    local job_id="$2"

    local job_name
    job_name=$(get_job_name "${pr}" "${job_id}")

    local url="${GCS_BASE}/pr-logs/pull/openshift_release/${pr}/${job_name}/${job_id}/started.json"
    fetch_url "${url}"
}

function fetch_clone_records() {
    local pr="$1"
    local job_id="$2"

    local job_name
    job_name=$(get_job_name "${pr}" "${job_id}")

    local url="${GCS_BASE}/pr-logs/pull/openshift_release/${pr}/${job_name}/${job_id}/artifacts/clone-records.json"
    fetch_url "${url}"
}

# Main execution
function main() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi

    local cmd="$1"
    shift

    case "${cmd}" in
        http*://*)
            # Direct URL
            fetch_url "${cmd}"
            ;;
        pr-checks)
            if [[ $# -lt 1 ]]; then
                log_error "pr-checks command requires PR"
                show_usage
                exit 1
            fi
            pr_checks "$1" "${2:-rehearse}"
            ;;
        build-log)
            if [[ $# -lt 3 ]]; then
                log_error "build-log command requires PR JOB_ID STEP_NAME"
                show_usage
                exit 1
            fi
            fetch_build_log "$1" "$2" "$3"
            ;;
        finished)
            if [[ $# -lt 2 ]]; then
                log_error "finished command requires PR JOB_ID"
                show_usage
                exit 1
            fi
            fetch_finished "$1" "$2"
            ;;
        started)
            if [[ $# -lt 2 ]]; then
                log_error "started command requires PR JOB_ID"
                show_usage
                exit 1
            fi
            fetch_started "$1" "$2"
            ;;
        clone-records)
            if [[ $# -lt 2 ]]; then
                log_error "clone-records command requires PR JOB_ID"
                show_usage
                exit 1
            fi
            fetch_clone_records "$1" "$2"
            ;;
        --help|-h|help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown command: ${cmd}"
            log_error "For direct URLs, make sure they start with http:// or https://"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
