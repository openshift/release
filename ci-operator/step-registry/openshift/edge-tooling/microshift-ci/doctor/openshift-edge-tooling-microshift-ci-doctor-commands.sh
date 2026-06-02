#!/bin/bash
set -euo pipefail
set -x

# Set global variables
WORKDIR="/tmp/microshift-ci-claude-workdir.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

CLAUDE_HOME="/home/claude/.claude"
mkdir -p "${CLAUDE_HOME}"

CLAUDE_DOCTOR_LOG="${WORKDIR}/claude-doctor.log"
CLAUDE_CREATE_BUGS_LOG="${WORKDIR}/claude-create-bugs.log"
CLAUDE_FIX_TEST_BUGS_LOG="${WORKDIR}/claude-fix-test-bugs.log"
CLAUDE_DOCTOR_REFRESH_LOG="${WORKDIR}/claude-doctor-refresh.log"
MCP_JIRA_LOG="${WORKDIR}/mcp-jira.log"

# The procedure to copy reports and session logs to artifacts, executed at exit
atexit_handler() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying report files to the artifact directory..."
        # Sync report files: skip project/artifact/sos dirs, enter first-level subdirs only,
        # copy html/json/txt/log files, ignore everything else, prune empty dirs
        rsync -am --no-perms \
            --exclude='microshift/' --exclude='artifacts/' --exclude='sos*/' \
            --include='/*/' --exclude='*/' \
            --include='*.html' --include='*.json' --include='*.txt' --include='*.log' \
            --exclude='*' \
            "${WORKDIR}/" "${ARTIFACT_DIR}/"
    fi

    # Archive the full Claude session directory (including subagent logs) for session continuation.
    # These are used by the openshift-claude-post step to generate the continue-session page.
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi

    # Check if the HTML report was produced
    if ls "${WORKDIR}"/*.html &>/dev/null; then
        touch "${SHARED_DIR}/claude-report-available"
        echo "Analysis complete"
    else
        echo "ERROR: No HTML report was generated"
        return 1
    fi

    # Check if the Claude sessions were completed successfully
    for log_file in "${CLAUDE_DOCTOR_LOG}" "${CLAUDE_CREATE_BUGS_LOG}" "${CLAUDE_FIX_TEST_BUGS_LOG}" "${CLAUDE_DOCTOR_REFRESH_LOG}"; do
        # If a session was terminated due to a timeout, report lack of
        # subsequent session log files as a warning and continue not
        # to mask the actual error
        if [ ! -f "${log_file}" ]; then
            echo "WARNING: Log file '${log_file}' not found"
            continue
        fi

        local result_line
        result_line="$(grep '"type":"result"' "${log_file}" | tail -1 || true)"
        if [[ -z "${result_line}" ]]; then
            echo "ERROR: No Claude result event found in '${log_file}'"
            return 1
        fi
        if ! echo "$result_line" | grep -q '"subtype":"success"' ||
           ! echo "$result_line" | grep -q '"is_error":false'; then
            echo "ERROR: Claude session in '${log_file}' did not complete successfully"
            return 1
        fi
    done
}

github_app_token() {
    local -r jwt="$1"
    local -r repo="$2"

    local install_id
    install_id="$(curl -s \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/installation" \
        | jq -r '.id')"
    if [ -z "${install_id}" ] || [ "${install_id}" = "null" ]; then
        echo "ERROR: Failed to get installation ID for ${repo}" >&2
        return 1
    fi

    curl -s -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${install_id}/access_tokens" \
        | jq -r '.token'
}

load_secrets() {
    # Disable command tracing to prevent leaking credentials in logs
    # and restore it after the secrets are loaded
    trap 'set -x' RETURN
    set +x

    echo "Loading secrets..."
    if [ -f "${GITHUB_APP_ID_PATH}" ] && [ -f "${GITHUB_KEY_PATH}" ]; then
        GITHUB_APP_JWT="$(gh-token generate \
            --app-id "$(< "${GITHUB_APP_ID_PATH}")" \
            --key "${GITHUB_KEY_PATH}" \
            --jwt \
            --token-only)"
        if [ -z "${GITHUB_APP_JWT}" ]; then
            echo "ERROR: Failed to generate GitHub App JWT"
            return 1
        fi

        GITHUB_TOKEN_USHIFT="$(github_app_token "${GITHUB_APP_JWT}" openshift/microshift)"
        if [ -z "${GITHUB_TOKEN_USHIFT}" ] || [ "${GITHUB_TOKEN_USHIFT}" = "null" ]; then
            echo "ERROR: Failed to generate installation access token for openshift/microshift"
            return 1
        fi

        echo "GitHub tokens generated."
    else
        echo "WARNING: GitHub App credentials not found at ${GITHUB_APP_ID_PATH} and ${GITHUB_KEY_PATH}. GitHub operations will not be available."
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
    # Disable command tracing to prevent leaking credentials in logs
    # and restore it after the function is executed
    trap 'set -x' RETURN
    set +x

    echo "Configuring Claude..."

    # Create an empty configuration file to avoid the "Claude configuration file
    # not found at: /home/claude/.claude/.claude.json" warning
    if [ ! -f "${CLAUDE_HOME}/.claude.json" ]; then
        echo "{}" > "${CLAUDE_HOME}/.claude.json"
    fi

    # Configure Claude permission-related settings
    cat > "${CLAUDE_HOME}/settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Read(//tmp/**)",
      "Write(//tmp/**)",
      "Bash(bash plugins/microshift-ci/scripts/*)",
      "Bash(python3 plugins/microshift-ci/scripts/*)",
      "Skill(microshift-ci:*)"
    ]
  }
}
EOF
    echo "Claude permissions configured."
    cat "${CLAUDE_HOME}/settings.json"

    # Configure JIRA MCP, redirecting stderr to the JIRA MCP log file.
    # Set MCP_VERBOSE=true to enable verbose logging.
    if [[ -n "${JIRA_API_TOKEN:-}" ]] && [[ -n "${JIRA_USERNAME:-}" ]]; then
        echo "Configuring JIRA MCP..."
        claude mcp add \
            -e JIRA_URL="${JIRA_URL}" \
            -e JIRA_API_TOKEN="${JIRA_API_TOKEN}" \
            -e JIRA_USERNAME="${JIRA_USERNAME}" \
            -e MCP_VERBOSE=true \
            --scope user \
            --transport stdio \
            jira -- bash -c "uvx mcp-atlassian@0.21.0 2>>${MCP_JIRA_LOG}"

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

# This job should only run from the main branch
if [[ "${JOB_NAME}" != *-main-microshift-ci-doctor ]]; then
    echo "ERROR: This job should only run from the main branch (JOB_NAME=${JOB_NAME})"
    exit 1
fi

# Ensure reports and session logs are copied to artifacts
trap atexit_handler EXIT TERM INT

load_secrets
configure_claude

# Use the edge-tooling source pre-installed in the image
SRC_DIR="${EDGE_TOOLING_DIR}"
PLUGIN_DIR="${SRC_DIR}/plugins/microshift-ci"
cd "${SRC_DIR}"

# Configure the GitHub token for MicroShift repo operations
{ set +x; export GITHUB_TOKEN="${GITHUB_TOKEN_USHIFT}"; set -x; }

# Close duplicate rebase PRs before running the analysis to prevent them
# from being included in the analysis and bug creation.
echo "Running automatic closing of duplicate rebase PRs..."
"${PLUGIN_DIR}/scripts/prow-jobs-for-pull-requests.sh" \
    --mode close-duplicates \
    --execute \
    --author 'microshift-rebase-script[bot]' \
    --filter 'NO-ISSUE: rebase-release'
echo "Automatic closing of duplicate rebase PRs completed"

# Run analysis on all releases and open rebase PRs (45m and 100 turns).
echo "Running Claude to analyze MicroShift CI jobs and pull requests..."
timeout 2700 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 100 \
    --output-format stream-json \
    --plugin-dir "${PLUGIN_DIR}" \
    -p "/microshift-ci:doctor ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${CLAUDE_DOCTOR_LOG}"
echo "Analysis for MicroShift CI jobs and pull requests completed"

# Run bug creation for failed jobs (10m and 50 turns).
echo "Running Claude to create bugs for failed jobs..."
timeout 600 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 50 \
    --output-format stream-json \
    --plugin-dir "${PLUGIN_DIR}" \
    -p "/microshift-ci:create-bugs ${RELEASE_VERSIONS} --create" \
    --verbose 2>&1 | tee "${CLAUDE_CREATE_BUGS_LOG}"
echo "Bug creation for failed jobs completed"

# Run bug fix for test bugs (5m and 20 turns).
# Dry-run mode only.
echo "Running Claude to fix test bugs (dry-run mode)..."
timeout 300 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 20 \
    --output-format stream-json \
    --plugin-dir "${PLUGIN_DIR}" \
    -p "/microshift-ci:fix-test-bugs ${RELEASE_VERSIONS} --open" \
    --verbose 2>&1 | tee "${CLAUDE_FIX_TEST_BUGS_LOG}"
echo "Bug fix for test bugs (dry-run mode) completed"

# Run HTML report refresh to include the new bugs (5m and 30 turns).
echo "Running Claude to refresh the HTML report..."
timeout 300 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 30 \
    --output-format stream-json \
    --plugin-dir "${PLUGIN_DIR}" \
    -p "/microshift-ci:doctor-refresh ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${CLAUDE_DOCTOR_REFRESH_LOG}"
echo "HTML report refresh completed"

# Now attempt to restart failed rebase PRs tests. If the restarted tests
# complete successfully, the PR will be automatically merged.
echo "Running automatic restart of failed rebase PRs tests..."
"${PLUGIN_DIR}/scripts/prow-jobs-for-pull-requests.sh" \
    --mode restart \
    --execute \
    --author 'microshift-rebase-script[bot]'
echo "Automatic restart of failed rebase PRs tests completed"
