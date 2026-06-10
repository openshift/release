#!/usr/bin/bash
set -euo pipefail
set -x

echo "=== MicroShift Release Evaluation ==="
echo "Started at $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "Time range: ${PRECHECK_TIME_RANGE}"

# Set global variables
WORKDIR="/tmp/microshift-release-eval.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

CLAUDE_HOME="${HOME}/.claude"
mkdir -p "${CLAUDE_HOME}"

CLAUDE_LOG="${WORKDIR}/claude-precheck.log"
RESULTS_TEXT="${WORKDIR}/precheck-results.txt"
MCP_JIRA_LOG="${WORKDIR}/mcp-jira.log"

# The procedure to copy artifacts and results to SHARED_DIR, executed at exit
atexit_handler() {
    echo "Copying artifacts..."
    cp -f "${CLAUDE_LOG}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    cp -f "${RESULTS_TEXT}" "${ARTIFACT_DIR}/" 2>/dev/null || true

    if [[ -f "${RESULTS_TEXT}" ]]; then
        cp -f "${RESULTS_TEXT}" "${SHARED_DIR}/precheck-results.txt"
        touch "${SHARED_DIR}/precheck-completed"
        echo "Pre-check results saved."
        return 0
    fi

    # Fallback: extract text from Claude stream-json result event
    # NOTE: This attempts to parse a custom "result" event from the Claude log.
    # Standard Claude stream-json uses message_start/content_block_delta/message_stop events.
    # This may not work with vanilla Claude output - verify the event exists in the log.
    if [[ -f "${CLAUDE_LOG}" ]]; then
        local result_text
        result_text="$(grep '"type":"result"' "${CLAUDE_LOG}" | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"
        if [[ -n "${result_text}" ]]; then
            echo "${result_text}" > "${SHARED_DIR}/precheck-results.txt"
            echo "${result_text}" > "${ARTIFACT_DIR}/precheck-results.txt"
            touch "${SHARED_DIR}/precheck-completed"
            echo "Pre-check results extracted from Claude log."
            return 0
        else
            echo "WARNING: No 'result' event found in Claude log. Fallback extraction failed."
        fi
    fi

    echo "WARNING: No pre-check results produced."
}
trap atexit_handler EXIT TERM INT

check_claude_rc() {
    local -r rc="$1"
    local -r session="$2"
    local -r timeout_min="$3"

    if [ "${rc}" -eq 124 ]; then
        echo "ERROR: Claude ${session} session timed out after ${timeout_min} minutes"
        exit 1
    elif [ "${rc}" -ne 0 ]; then
        echo "ERROR: Claude ${session} session failed with exit code ${rc}"
        exit 1
    fi
    echo "Claude ${session} session completed successfully"
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

    # GitHub token: use provided GITHUB_TOKEN or generate from App credentials
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "Using provided GITHUB_TOKEN."
    elif [[ -f "${GITHUB_APP_ID_PATH}" ]] && [[ -f "${GITHUB_KEY_PATH}" ]]; then
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
        echo "ERROR: Neither GITHUB_TOKEN nor GitHub App credentials (${GITHUB_APP_ID_PATH}, ${GITHUB_KEY_PATH}) provided."
        return 1
    fi

    if [[ -f "${JIRA_API_TOKEN_PATH}" ]]; then
        JIRA_API_TOKEN=$(cat "${JIRA_API_TOKEN_PATH}")
        export JIRA_API_TOKEN
        export ATLASSIAN_API_TOKEN="${JIRA_API_TOKEN}"
        echo "Jira API token loaded."
    else
        echo "ERROR: Jira API token not found at ${JIRA_API_TOKEN_PATH}."
        return 1
    fi

    if [[ -f "${JIRA_USERNAME_PATH}" ]]; then
        JIRA_USERNAME=$(cat "${JIRA_USERNAME_PATH}")
        export JIRA_USERNAME
        export ATLASSIAN_EMAIL="${JIRA_USERNAME}"
        echo "Jira username loaded."
    else
        echo "ERROR: Jira username not found at ${JIRA_USERNAME_PATH}."
        return 1
    fi
}

wait_for_mcp_status() {
    local -r service="$1"
    local -r status="$2"
    local -r timeout="${3:-120}"
    local -r interval="${4:-5}"

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
      "Bash(bash /tmp/edge-tooling/plugins/microshift-release/scripts/*)",
      "Bash(bash plugins/microshift-release/scripts/*)",
      "Bash(*bash plugins/microshift-release/scripts/*)",
      "Bash(python3 /tmp/edge-tooling/plugins/microshift-release/scripts/*)",
      "Bash(python3 plugins/microshift-release/scripts/*)",
      "Bash(python3:*)",
      "Bash(tee /tmp/**)",
      "Bash(git rev-parse *)",
      "Bash(git fetch *)",
      "Bash(git clone *)",
      "Bash(git sparse-checkout *)",
      "Bash(git branch *)",
      "Bash(git log *)",
      "Bash(mkdir -p *)",
      "Bash(python3 -m venv *)",
      "Bash(python3 -m pip install *)",
      "Skill(microshift-release:pre-check)",
      "mcp__jira__*",
      "mcp__atlassian__*"
    ]
  }
}
EOF
    echo "Claude permissions configured."
    cat "${CLAUDE_HOME}/settings.json"

    # Configure Atlassian MCP server
    cat > "${CLAUDE_HOME}/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "atlassian": {
      "url": "https://mcp.atlassian.com/v1/mcp/authv2",
      "type": "http"
    }
  }
}
EOF
    echo "MCP servers configured."
    cat "${CLAUDE_HOME}/.mcp.json"

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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Starting MicroShift Release Evaluation"

# This job should only run from the main branch
if [[ "${JOB_NAME}" != *-main-microshift-release-evaluation ]]; then
    echo "ERROR: This job should only run from the main branch (JOB_NAME=${JOB_NAME})"
    exit 1
fi

load_secrets
configure_claude

# Use the edge-tooling source pre-installed in the image
SRC_DIR="${EDGE_TOOLING_DIR}"
PLUGIN_DIR="${SRC_DIR}/plugins/microshift-release"
cd "${SRC_DIR}"

# Configure the GitHub token for MicroShift repo operations
{ set +x; export GITHUB_TOKEN="${GITHUB_TOKEN:-GITHUB_TOKEN_USHIFT}"; set -x; }

# Workaround: --continue + -p is broken (anthropics/claude-code#42376).
export CLAUDE_CODE_ENTRYPOINT=cli

# Clone MicroShift repo (needed for git-based commit analysis in precheck_xyz.py)
MICROSHIFT_DIR="/tmp/microshift"
if [[ -d "${MICROSHIFT_DIR}/.git" ]]; then
    echo "MicroShift repository already cloned, fetching latest..."
    git -C "${MICROSHIFT_DIR}" fetch --all --quiet
else
    echo "Cloning MicroShift repository..."
    git clone --filter=blob:none https://github.com/openshift/microshift.git "${MICROSHIFT_DIR}"
fi
echo "MicroShift repo cloned."

# Run Claude to analyze MicroShift Z-Stream releases
echo "Running Claude to analyze MicroShift Z-Stream releases..."
CLAUDE_RC=0
timeout 1200 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 50 \
    --output-format stream-json \
    --plugin-dir "${PLUGIN_DIR}" \
    -p "/microshift-release:pre-check ${PRECHECK_TIME_RANGE} --verbose" \
    --verbose 2>&1 | tee "${CLAUDE_LOG}"
check_claude_rc "${CLAUDE_RC}" "pre-check" 20

echo "=== MicroShift Release Evaluation complete ==="
