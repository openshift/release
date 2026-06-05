#!/usr/bin/env bash
#
# analyze-prowjob.sh - Wrapper for prowjob-analyzer dig.py
#
# Analyzes OpenShift Prow job results using the prowjob-analyzer tool
# from the sandboxed-containers-operator repository.
#
# Usage:
#   analyze-prowjob.sh <PROW_JOB_URL> [options]
#
# Examples:
#   analyze-prowjob.sh https://prow.ci.openshift.org/view/gs/.../79244/.../2056394548283707392
#   analyze-prowjob.sh <PROW_JOB_URL> --json
#   analyze-prowjob.sh <PROW_JOB_URL> --verbose
#
# Environment Variables:
#   PROWJOB_ANALYZER_CACHE - Directory for cached analyzer repo (default: ~/.cache/prowjob-analyzer)
#   PROWJOB_ANALYZER_BRANCH - Branch to use (default: devel)
#

set -euo pipefail

# Configuration
CACHE_DIR="${PROWJOB_ANALYZER_CACHE:-${HOME}/.cache/prowjob-analyzer}"
BRANCH="${PROWJOB_ANALYZER_BRANCH:-devel}"
REPO_URL="https://github.com/openshift/sandboxed-containers-operator.git"
ANALYZER_SCRIPT="scripts/prowjob-analyzer/dig.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_info() {
    echo -e "${GREEN}[analyze-prowjob]${NC} $*" >&2
}

function log_warn() {
    echo -e "${YELLOW}[analyze-prowjob]${NC} $*" >&2
}

function log_error() {
    echo -e "${RED}[analyze-prowjob]${NC} $*" >&2
}

function ensure_analyzer() {
    # Check if analyzer is already cached
    if [[ -d "${CACHE_DIR}" && -f "${CACHE_DIR}/${ANALYZER_SCRIPT}" ]]; then
        log_info "Using cached prowjob-analyzer at ${CACHE_DIR}"

        # Optionally update if it's been more than 24 hours
        if [[ -f "${CACHE_DIR}/.last_update" ]]; then
            local last_update
            last_update=$(cat "${CACHE_DIR}/.last_update")
            local now
            now=$(date +%s)
            local age=$((now - last_update))

            # Update if older than 24 hours (86400 seconds)
            if [[ ${age} -gt 86400 ]]; then
                log_info "Cache is older than 24 hours, updating..."
                update_analyzer
            fi
        fi
    else
        log_info "Cloning prowjob-analyzer to ${CACHE_DIR}..."
        clone_analyzer
    fi
}

function clone_analyzer() {
    mkdir -p "$(dirname "${CACHE_DIR}")"

    if ! git clone -b "${BRANCH}" --depth 1 "${REPO_URL}" "${CACHE_DIR}" >&2; then
        log_error "Failed to clone prowjob-analyzer repository"
        return 1
    fi

    date +%s > "${CACHE_DIR}/.last_update"
    log_info "Prowjob-analyzer cloned successfully"
}

function update_analyzer() {
    pushd "${CACHE_DIR}" > /dev/null

    if git pull origin "${BRANCH}" >&2; then
        date +%s > "${CACHE_DIR}/.last_update"
        log_info "Prowjob-analyzer updated successfully"
    else
        log_warn "Failed to update, using cached version"
    fi

    popd > /dev/null
}

function check_dependencies() {
    # Check for required commands
    local missing_deps=()

    for cmd in python3 git; do
        if ! command -v "${cmd}" &> /dev/null; then
            missing_deps+=("${cmd}")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install: ${missing_deps[*]}"
        return 1
    fi
}

function show_usage() {
    cat >&2 << 'EOF'
Usage: analyze-prowjob.sh <PROW_JOB_URL> [options]

Analyzes OpenShift Prow job results using prowjob-analyzer from
https://github.com/openshift/sandboxed-containers-operator (devel branch)

Arguments:
  PROW_JOB_URL    Prow job URL to analyze

Options:
  --json          Output in JSON format
  --verbose       Enable verbose logging
  --no-wait       Don't wait for artifacts to be ready
  --help          Show this help message

Examples:
  # Analyze a Prow job
  analyze-prowjob.sh https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/openshift_release/79244/rehearse-.../2056394548283707392

  # Get JSON output
  analyze-prowjob.sh <PROW_URL> --json

  # Verbose output
  analyze-prowjob.sh <PROW_URL> --verbose

Environment Variables:
  PROWJOB_ANALYZER_CACHE   Cache directory (default: ~/.cache/prowjob-analyzer)
  PROWJOB_ANALYZER_BRANCH  Git branch to use (default: devel)

Output:
  The analyzer provides:
  - Job metadata (provider, OCP version, workload type, etc.)
  - Overall job status (pass/fail/timeout)
  - Failed step identification
  - Test result summary
  - Pattern detection for common failures

For more information, see:
https://github.com/openshift/sandboxed-containers-operator/blob/devel/scripts/prowjob-analyzer/README.md
EOF
}

# Main execution
function main() {
    # Handle --help
    if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
        show_usage
        exit 0
    fi

    # Check dependencies
    check_dependencies

    # Ensure analyzer is available
    ensure_analyzer

    # Change to analyzer directory and run dig.py
    cd "${CACHE_DIR}/scripts/prowjob-analyzer"

    # Run dig.py with all arguments passed through
    exec python3 dig.py "$@"
}

main "$@"
