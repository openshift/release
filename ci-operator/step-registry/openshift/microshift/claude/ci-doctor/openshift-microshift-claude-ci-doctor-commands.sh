#!/bin/bash
set -euo pipefail
set -x

echo "Starting MicroShift Claude CI Doctor"

# Install gcloud CLI for GCS artifact access (no root required)
echo "Installing gcloud CLI..."
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
/tmp/google-cloud-sdk/install.sh --quiet --path-update true
export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
echo "gcloud CLI installed."

# Clone the MicroShift repository
SRC_DIR="/tmp/microshift"
git clone https://github.com/openshift/microshift.git /tmp
cd "${SRC_DIR}"

# Set the work directory
WORKDIR="/tmp/analyze-ci-claude-workdir.$(date +%y%m%d)"
mkdir -p "${WORKDIR}"

# Run Claude to analyze the release
echo "Invoking Claude to analyze MicroShift CI jobs and pull requests..."

# Ensure reports and session logs are copied to artifacts even if the script exits early
copy_reports() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying reports to artifact directory..."
        find "${WORKDIR}" -maxdepth 1 -name "*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -maxdepth 1 -name "*.txt"  -exec cp {} "${ARTIFACT_DIR}/" \; || true
    fi

    # Archive the full Claude session directory (including subagent logs) for session continuation.
    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}
trap copy_reports EXIT TERM INT

ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

SYSTEM_PROMPT="
You are a diligent senior OpenShift release engineer analyzing CI for MicroShift releases.

**CRITICAL**: You have many analyze-ci skills at your disposal.
You MUST load the relevant analyze-ci skills using the Skill tool BEFORE you begin any work.
Do NOT improvise or guess.
"

RELEASE_VERSIONS="main,4.22"

timeout 3600 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    --append-system-prompt "${SYSTEM_PROMPT}" \
    -p "/analyze-ci-for-release-manager ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${WORKDIR}/claude-output.log"

# Check if we produced a report
if ls "${WORKDIR}"/*.html 1>/dev/null 2>&1; then
    echo "Analysis complete."
else
    echo "Warning: No HTML report was generated."
    exit 1
fi
