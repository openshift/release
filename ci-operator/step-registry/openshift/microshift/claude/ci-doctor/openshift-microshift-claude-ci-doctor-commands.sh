#!/bin/bash
set -euo pipefail
set -x

# Set global variables
WORKDIR="/tmp/analyze-ci-claude-workdir.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

CLAUDE_HOME="/home/claude/.claude"
mkdir -p "${CLAUDE_HOME}"

load_secrets() {
    if [ -f "${GITHUB_TOKEN_PATH}" ]; then
        export GITHUB_TOKEN
        GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
        echo "GitHub token loaded."
    else
        echo "Warning: GitHub token not found at ${GITHUB_TOKEN_PATH}. Revert operations will not be available."
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
        echo "Copying reports to artifact directory..."
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${SHARED_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.txt"  -exec cp {} "${ARTIFACT_DIR}/" \; || true
    fi

    # Archive the full Claude session directory (including subagent logs) for session continuation.
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}

configure_claude() {
    echo "Configuring Claude..."

    # Create empty configuration file to avoid the following warning:
    # Claude configuration file not found at: /home/claude/.claude/.claude.json
    if [ ! -f "${CLAUDE_HOME}/.claude.json" ]; then
        echo "{}" > "${CLAUDE_HOME}/.claude.json"
    fi

    # Configure Claude settings
    cat > "${CLAUDE_HOME}/settings.json" <<EOF
{
  "model": "${CLAUDE_MODEL}",
  "enabledPlugins": {
    "jira@ai-helpers": true
  },
  "extraKnownMarketplaces": {
    "ai-helpers": {
      "source": {
        "source": "github",
        "repo": "openshift-eng/ai-helpers"
      }
    }
  },
  "effortLevel": "medium",
  "skipDangerousModePermissionPrompt": true
}
EOF
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

# Load secrets with command tracing disabled to prevent leaking credentials in logs
{
    set +x
    load_secrets
}
install_prerequisites
configure_claude

echo "Running Claude to analyze MicroShift CI jobs and pull requests..."
claude \
    --model "${CLAUDE_MODEL}" \
    --output-format stream-json \
    -p "/analyze-ci:doctor ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${WORKDIR}/claude-output.log"

# Check if the report was produced
if ls "${WORKDIR}"/*.html &>/dev/null; then
    touch "${SHARED_DIR}/claude-report-available"
    echo "Analysis complete"
else
    echo "ERROR: No HTML report was generated"
    exit 1
fi
