#!/bin/bash
set -euo pipefail
set -x

# Set global variables
WORKDIR="/tmp/analyze-ci-claude-workdir.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

CLAUDE_HOME="/home/claude/.claude"
mkdir -p "${CLAUDE_HOME}"

load_secrets() {
    # Disable command tracing to prevent leaking credentials in logs
    # and restore it after the secrets are loaded
    trap 'set -x' RETURN
    set +x

    echo "Loading secrets..."
    if [ -f "${GITHUB_TOKEN_PATH}" ]; then
        GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
        export GITHUB_TOKEN
        echo "GitHub token loaded."
    else
        echo "WARNING: GitHub token not found at ${GITHUB_TOKEN_PATH}. GutHub operations will not be available."
    fi

    if [ -f "${JIRA_API_TOKEN_PATH}" ]; then
        JIRA_API_TOKEN=$(cat "${JIRA_API_TOKEN_PATH}")
        export JIRA_API_TOKEN
        echo "Jira API token loaded."
    else
        echo "WARNING: Jira API token not found at ${JIRA_API_TOKEN_PATH}. Jira operations will not be available."
    fi

    if [ -f "${JIRA_USERNAME_PATH}" ]; then
        JIRA_USERNAME=$(cat "${JIRA_USERNAME_PATH}")
        export JIRA_USERNAME
        echo "Jira username loaded."
    else
        echo "WARNING: Jira username not found at ${JIRA_USERNAME_PATH}. Jira operations will not be available."
    fi
}

install_prerequisites() {
    echo "Installing gcloud CLI..."

    curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
    /tmp/google-cloud-sdk/install.sh --quiet --path-update true
    export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
    echo "gcloud CLI installed."
}

# Copy reports and session logs to artifacts
copy_reports() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying reports to artifact and shared directories..."
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${SHARED_DIR}/"   \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.txt"  -exec cp {} "${ARTIFACT_DIR}/" \; || true
    fi

    # Archive the full Claude session directory (including subagent logs) for session continuation.
    # These are used by the openshift-claude-post step to generate the continue-session page.
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}

wait_for_mcp_status() {
    local -r service="$1"
    local -r status="$2"
    local -r timeout="${3:-120}"  # seconds
    local -r interval="${4:-5}"   # seconds

    local -r attempts=$((timeout / interval))
    for ((i=0; i<attempts; i++)); do
        if claude mcp list | grep "^${service}:" | grep -q "${status}"; then
            return 0
        fi
        sleep "${interval}"
    done

    echo "ERROR: MCP service '${service}' did not reach status '${status}' after ${timeout} seconds."
    return 1
}

configure_claude() {
    echo "Configuring Claude..."

    # Create an empty configuration file to avoid the "Claude configuration file
    # not found at: /home/claude/.claude/.claude.json" warning
    if [ ! -f "${CLAUDE_HOME}/.claude.json" ]; then
        echo "{}" > "${CLAUDE_HOME}/.claude.json"
    fi

    # Configure JIRA MCP
    if [[ -n "${JIRA_API_TOKEN:-}" ]] && [[ -n "${JIRA_USERNAME:-}" ]]; then
        echo "Configuring JIRA MCP..."

        pip install uv --user --upgrade
        # Load secrets with command tracing disabled to prevent leaking credentials in logs
        {
          set +x
          claude mcp add \
              -e JIRA_URL="${JIRA_URL}" -e JIRA_API_TOKEN="${JIRA_API_TOKEN}" -e JIRA_USERNAME="${JIRA_USERNAME}" \
              --transport stdio jira -- uvx mcp-atlassian
          set -x
        }

        echo "Waiting for JIRA MCP to become available..."
        wait_for_mcp_status "jira" "Connected"
        echo "JIRA MCP is available."
    else
        echo "WARNING: Jira API token or username not available. Jira MCP will not be available."
    fi
}

#
# Main
#
echo "Starting MicroShift Claude CI Doctor"

# Ensure reports and session logs are copied to artifacts
trap copy_reports EXIT TERM INT

# Clone the MicroShift repository from the main branch to get the latest
# analyze-ci skills and run analysis on all releases and open pull requests
SRC_DIR="/tmp/microshift"
git clone -b main https://github.com/openshift/microshift.git "${SRC_DIR}"
cd "${SRC_DIR}"

load_secrets
install_prerequisites
configure_claude

# Run analysis on all releases and open rebase PRs.
# Time-box analysis and limit turns to avoid uncontrolled billable minutes.
echo "Running Claude to analyze MicroShift CI jobs and pull requests..."
timeout 3600 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 50 \
    --output-format stream-json \
    -p "/analyze-ci:doctor ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${WORKDIR}/claude-output.log"

# After the analysis, run automatic approval of rebase PRs with all tests passing
echo "Running automatic approval of rebase PRs with all tests passing..."
.claude/scripts/microshift-prow-jobs-for-pull-requests.sh \
    --mode approve \
    --author 'microshift-rebase-script[bot]'
echo "Automatic approval of rebase PRs with all tests passing completed"

# After the analysis, attempt to restart failed rebase PRs tests. If the
# restarted tests complete successfully, the PR will be automatically
# approved next time the analysis runs.
echo "Running automatic restart of failed rebase PRs tests..."
.claude/scripts/microshift-prow-jobs-for-pull-requests.sh \
    --mode restart \
    --author 'microshift-rebase-script[bot]'
echo "Automatic restart of failed rebase PRs tests completed"

# Check if the report was produced
if ls "${WORKDIR}"/*.html &>/dev/null; then
    touch "${SHARED_DIR}/claude-report-available"
    echo "Analysis complete"
else
    echo "ERROR: No HTML report was generated"
    exit 1
fi
