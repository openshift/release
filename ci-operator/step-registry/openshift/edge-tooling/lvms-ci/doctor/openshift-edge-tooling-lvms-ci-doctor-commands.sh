#!/bin/bash
set -euo pipefail
set -x

# Set global variables
WORKDIR="/tmp/lvm-operator-ci-claude-workdir.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

CLAUDE_HOME="/home/claude/.claude"
mkdir -p "${CLAUDE_HOME}"

CLAUDE_DOCTOR_LOG="${WORKDIR}/claude-doctor.log"

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

        GITHUB_TOKEN_LVM="$(github_app_token "${GITHUB_APP_JWT}" openshift/lvm-operator)"
        if [ -z "${GITHUB_TOKEN_LVM}" ] || [ "${GITHUB_TOKEN_LVM}" = "null" ]; then
            echo "ERROR: Failed to generate installation access token for openshift/lvm-operator"
            return 1
        fi

        echo "GitHub token generated."
    else
        echo "WARNING: GitHub App credentials not found at ${GITHUB_APP_ID_PATH} and ${GITHUB_KEY_PATH}. GitHub operations will not be available."
    fi
}

# The procedure to copy reports and session logs to artifacts, executed at exit
atexit_handler() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying report files to the artifact directory..."
        # Sync report files: skip project/artifact/sos dirs, enter first-level subdirs only,
        # copy html/json/txt/log files, ignore everything else, prune empty dirs
        rsync -am --no-perms \
            --exclude='lvm-operator/' --exclude='artifacts/' --exclude='sos*/' \
            --include='/*/' --exclude='*/' \
            --include='*.html' --include='*.json' --include='*.txt' --include='*.log' \
            --exclude='*' \
            "${WORKDIR}/" "${ARTIFACT_DIR}/"
    fi

    # Archive the full Claude session directory (including subagent logs) for debugging.
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

    # Check if the Claude session completed successfully
    if [ ! -f "${CLAUDE_DOCTOR_LOG}" ]; then
        echo "WARNING: Log file '${CLAUDE_DOCTOR_LOG}' not found"
        return 1
    fi

    local result_line
    result_line="$(grep '"type":"result"' "${CLAUDE_DOCTOR_LOG}" | tail -1 || true)"
    if [[ -z "${result_line}" ]]; then
        echo "ERROR: No Claude result event found in '${CLAUDE_DOCTOR_LOG}'"
        return 1
    fi
    if ! echo "$result_line" | grep -q '"subtype":"success"' ||
       ! echo "$result_line" | grep -q '"is_error":false'; then
        echo "ERROR: Claude session did not complete successfully"
        return 1
    fi
}

configure_claude() {
    echo "Configuring Claude..."

    # Create an empty configuration file
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
      "Bash(bash plugins/*/scripts/*)",
      "Bash(python3 plugins/*/scripts/*)",
      "Skill(lvms-ci:*)"
    ]
  }
}
EOF
    echo "Claude permissions configured."
    cat "${CLAUDE_HOME}/settings.json"
}

#
# Main
#
echo "Starting LVMS Claude CI Doctor"

# Ensure reports and session logs are copied to artifacts
trap atexit_handler EXIT TERM INT

load_secrets
configure_claude

# Use the edge-tooling source pre-installed in the image
SRC_DIR="${EDGE_TOOLING_DIR}"
PLUGIN_DIR="${SRC_DIR}/plugins/lvms-ci"
cd "${SRC_DIR}"

# Configure the GitHub token for lvm-operator repo operations
{ set +x; export GITHUB_TOKEN="${GITHUB_TOKEN_LVM}"; set -x; }

# Run analysis on all releases.
# Time-box analysis and limit turns to avoid uncontrolled billable minutes.
echo "Running Claude to analyze LVMS CI jobs..."
timeout 4800 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 100 \
    --output-format stream-json \
    --plugin-dir "${PLUGIN_DIR}" \
    -p "/lvms-ci:doctor ${RELEASE_VERSIONS}" \
    --verbose &> "${CLAUDE_DOCTOR_LOG}"
echo "Analysis for LVMS CI jobs completed"
