#!/bin/bash
set -euo pipefail
set -x

# Set global variables
WORKDIR="/tmp/lvm-operator-ci-claude-workdir.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

CLAUDE_HOME="/home/claude/.claude"
mkdir -p "${CLAUDE_HOME}"

CLAUDE_ANALYSIS_LOG="${WORKDIR}/claude-analysis.log"

# The procedure to copy reports and session logs to artifacts, executed at exit
atexit_handler() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying report files to the artifact directory..."
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.json" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.txt"  -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.log"  -exec cp {} "${ARTIFACT_DIR}/" \; || true
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
    if [ ! -f "${CLAUDE_ANALYSIS_LOG}" ]; then
        echo "WARNING: Log file '${CLAUDE_ANALYSIS_LOG}' not found"
        return 1
    fi

    local result_line
    result_line="$(grep '"type":"result"' "${CLAUDE_ANALYSIS_LOG}" | tail -1 || true)"
    if [[ -z "${result_line}" ]]; then
        echo "ERROR: No Claude result event found in '${CLAUDE_ANALYSIS_LOG}'"
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
      "Bash(bash plugins/lvms-ci/scripts/*)",
      "Bash(python3 plugins/lvms-ci/scripts/*)",
      "Skill(lvms-ci:doctor)",
      "Skill(lvms-ci:prow-job)"
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

configure_claude

# Use the edge-tooling source pre-installed in the image
SRC_DIR="${EDGE_TOOLING_DIR}"
PLUGIN_DIR="${SRC_DIR}/plugins/lvms-ci"
cd "${SRC_DIR}"

# Run analysis on all releases.
# Time-box analysis and limit turns to avoid uncontrolled billable minutes.
echo "Running Claude to analyze LVMS CI jobs..."
timeout 3000 claude \
    --model "${CLAUDE_MODEL}" \
    --max-turns 100 \
    --output-format stream-json \
    --plugin-dir "${PLUGIN_DIR}" \
    -p "/lvms-ci:doctor ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${CLAUDE_ANALYSIS_LOG}"
echo "Analysis for LVMS CI jobs completed"
