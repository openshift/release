#!/bin/bash
set -euo pipefail

echo "Starting MicroShift Claude CI Doctor"

# Load secrets with command tracing disabled to prevent leaking credentials in logs
set +x
if [ -f "${GITHUB_TOKEN_PATH}" ]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
    echo "GitHub token loaded."
else
    echo "Warning: GitHub token not found at ${GITHUB_TOKEN_PATH}. Revert operations will not be available."
fi

# Enable command tracing
set -x

# Install gcloud CLI for GCS artifact access (no root required)
echo "Installing gcloud CLI..."
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
/tmp/google-cloud-sdk/install.sh --quiet --path-update true
export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
echo "gcloud CLI installed."

# Clone the MicroShift repository
SRC_DIR="/tmp/microshift"
# TODO: Clone from the main branch
# git clone -b main https://github.com/openshift/microshift.git "${SRC_DIR}"
git clone -b analyze-ci-reorg https://github.com/ggiguash/microshift.git "${SRC_DIR}"
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

# ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

# SYSTEM_PROMPT="
# You are a diligent senior OpenShift release engineer analyzing CI for MicroShift releases.

# **CRITICAL**: You have many analyze-ci skills at your disposal.
# You MUST load the relevant analyze-ci skills using the Skill tool BEFORE you begin any work.
# Do NOT improvise or guess.
# "

#    --allowedTools "${ALLOWED_TOOLS}" \
#    --max-turns 100 \
#    --append-system-prompt "${SYSTEM_PROMPT}" \

# Configure Claude settings
CLAUDE_HOME="${HOME}/.claude"
mkdir -p "${CLAUDE_HOME}"
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

timeout 3600 claude \
    --output-format stream-json \
    -p "/analyze-ci:doctor ${RELEASE_VERSIONS}" \
    --verbose 2>&1 | tee "${WORKDIR}/claude-output.log"

# Check if we produced a report
if ls "${WORKDIR}"/*.html &>/dev/null; then
    echo "Analysis complete."
else
    echo "Warning: No HTML report was generated."
    exit 1
fi
