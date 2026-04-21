#!/bin/bash
set -euo pipefail
set -x

# Dummy change to trigger rehearsals

# Set global variables
WORKDIR="/tmp/microshift-ci-claude-workdir.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

CLAUDE_HOME="/home/claude/.claude"
mkdir -p "${CLAUDE_HOME}"

# The procedure to copy reports and session logs to artifacts, executed at exit
atexit_handler() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying reports to artifact and shared directories..."
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.json" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.txt"  -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${SHARED_DIR}/"   \; || true
    fi

    # Archive the full Claude session directory (including subagent logs) for session continuation.
    # These are used by the openshift-claude-post step to generate the continue-session page.
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi

    # Check if the report was produced
    if ls "${WORKDIR}"/*.html &>/dev/null; then
        touch "${SHARED_DIR}/claude-report-available"
        echo "Analysis complete"
    else
        echo "ERROR: No HTML report was generated"
        return 1
    fi

    # Check if Claude log contains tool errors
    if grep -q '"is_error":\s*true' "${WORKDIR}/claude-output.log"; then
        echo "ERROR: Claude log contains tool errors"
        return 1
    fi
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
        local -r app_ver="2.0.8"
        local -r app_sha="867d9ebf7dd18e67e2599f0f890f3f41b8673e88c4394a32a05476024c41ea0f"
        local -r app_exe="/tmp/gh-token-${app_ver}"

        curl -sSL \
            "https://github.com/Link-/gh-token/releases/download/v${app_ver}/linux-amd64" \
            -o "${app_exe}"
        if ! echo "${app_sha}  ${app_exe}" | sha256sum -c -; then
            echo "ERROR: Failed to verify GitHub CLI extension checksum"
            return 1
        fi
        chmod +x "${app_exe}"

        GITHUB_APP_JWT="$("${app_exe}" generate \
            --app-id "$(< "${GITHUB_APP_ID_PATH}")" \
            --key "${GITHUB_KEY_PATH}" \
            --jwt \
            --token-only)"
        if [ -z "${GITHUB_APP_JWT}" ]; then
            echo "ERROR: Failed to generate GitHub App JWT"
            return 1
        fi
        rm -f "${app_exe}"

        GITHUB_TOKEN_USHIFT="$(github_app_token "${GITHUB_APP_JWT}" openshift/microshift)"
        if [ -z "${GITHUB_TOKEN_USHIFT}" ] || [ "${GITHUB_TOKEN_USHIFT}" = "null" ]; then
            echo "ERROR: Failed to generate installation access token for openshift/microshift"
            return 1
        fi

        GITHUB_TOKEN_EDGE="$(github_app_token "${GITHUB_APP_JWT}" openshift-eng/edge-tooling)"
        if [ -z "${GITHUB_TOKEN_EDGE}" ] || [ "${GITHUB_TOKEN_EDGE}" = "null" ]; then
            echo "ERROR: Failed to generate installation access token for openshift-eng/edge-tooling"
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

install_prerequisites() {
    # Export the PATH to include the local bin directory
    export PATH="${HOME}/.local/bin:${PATH}"

    echo "Installing gcloud CLI..."
    curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
    /tmp/google-cloud-sdk/install.sh --quiet --path-update true
    export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
    echo "gcloud CLI installed."

    echo "Installing Python package dependencies..."
    pip install --user \
        'uv==0.11.6' \
        'matplotlib==3.9.4'
    echo "Python package dependencies installed."
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
      "Bash(curl:*)",
      "Bash(date:*)",
      "Bash(cat:*)",
      "Bash(echo:*)",
      "Bash(wc:*)",
      "Bash(ls:*)",
      "Bash(jq:*)",
      "Skill(microshift-ci:create-bugs)",
      "Skill(microshift-ci:doctor)",
      "Skill(microshift-ci:prow-job)",
      "Skill(microshift-ci:test-job)",
      "Skill(microshift-ci:test-scenario)"
    ]
  }
}
EOF
    echo "Claude permissions configured."
    cat "${CLAUDE_HOME}/settings.json"

    # Configure JIRA MCP
    if [[ -n "${JIRA_API_TOKEN:-}" ]] && [[ -n "${JIRA_USERNAME:-}" ]]; then
        echo "Configuring JIRA MCP..."
        claude mcp add \
            -e JIRA_URL="${JIRA_URL}" \
            -e JIRA_API_TOKEN="${JIRA_API_TOKEN}" \
            -e JIRA_USERNAME="${JIRA_USERNAME}" \
            --scope user \
            --transport stdio \
            jira -- uvx mcp-atlassian@0.21.0

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

# CI Doctor should only run from the main branch
if [[ "${JOB_NAME}" != *-main-ci-doctor ]]; then
    echo "ERROR: CI Doctor should only run from the main branch job (JOB_NAME=${JOB_NAME})"
    exit 1
fi

# Ensure reports and session logs are copied to artifacts
trap atexit_handler EXIT TERM INT

load_secrets
install_prerequisites
configure_claude

# Clone the edge-tooling repository from the main branch to get the latest
# microshift-ci skills and run analysis on all releases and open pull requests
SRC_DIR="/tmp/edge-tooling"
EXE_DIR="${SRC_DIR}/plugins/microshift-ci/scripts"
{ set +x; export GITHUB_TOKEN="${GITHUB_TOKEN_EDGE}"; set -x; }
gh repo clone openshift-eng/edge-tooling "${SRC_DIR}" -- --branch main
cd "${SRC_DIR}"

# The rest of the script runs with the MicroShift GitHub token
{ set +x; export GITHUB_TOKEN="${GITHUB_TOKEN_USHIFT}"; set -x; }

# Run analysis on all releases and open rebase PRs.
# Time-box analysis and limit turns to avoid uncontrolled billable minutes.
echo "Running Claude to analyze MicroShift CI jobs and pull requests..."
timeout 3600 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 50 \
    --output-format stream-json \
    -p "/microshift-ci:doctor ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${WORKDIR}/claude-output.log"

# After the analysis, run automatic approval of rebase PRs with all tests passing
echo "Running automatic approval of rebase PRs with all tests passing..."
"${EXE_DIR}/prow-jobs-for-pull-requests.sh" \
    --mode approve \
    --execute \
    --author 'microshift-rebase-script[bot]'
echo "Automatic approval of rebase PRs with all tests passing completed"

# After the analysis, attempt to restart failed rebase PRs tests. If the
# restarted tests complete successfully, the PR will be automatically
# approved next time the analysis runs.
echo "Running automatic restart of failed rebase PRs tests..."
"${EXE_DIR}/prow-jobs-for-pull-requests.sh" \
    --mode restart \
    --execute \
    --author 'microshift-rebase-script[bot]'
echo "Automatic restart of failed rebase PRs tests completed"
