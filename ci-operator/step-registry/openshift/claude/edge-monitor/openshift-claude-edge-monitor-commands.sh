#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== Edge Enablement Payload Monitor ==="
echo "Started at $(date -u '+%Y-%m-%d %H:%M UTC')"

# ---------------------------------------------------------------------------
# Load secrets (xtrace disabled to prevent leaking credentials in logs)
# ---------------------------------------------------------------------------
set +x

if [[ -f "${JIRA_API_TOKEN_PATH}" ]]; then
    export JIRA_TOKEN
    JIRA_TOKEN=$(cat "${JIRA_API_TOKEN_PATH}")
    echo "JIRA token loaded."
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
build_prow_url() {
    if [[ "${JOB_TYPE:-}" == "presubmit" ]]; then
        echo "https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
    else
        echo "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
    fi
}

# ---------------------------------------------------------------------------
# Install gcloud CLI for Prow artifact access (no root required)
# ---------------------------------------------------------------------------
echo "Installing gcloud CLI..."
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
/tmp/google-cloud-sdk/install.sh --quiet --path-update true
export PATH="/tmp/google-cloud-sdk/bin:${PATH}"

# ---------------------------------------------------------------------------
# Configure Claude permissions for headless CI execution
# ---------------------------------------------------------------------------
CLAUDE_HOME="/home/claude/.claude"
mkdir -p "${CLAUDE_HOME}"

if [ ! -f "${CLAUDE_HOME}/.claude.json" ]; then
    echo "{}" > "${CLAUDE_HOME}/.claude.json"
fi

cat > "${CLAUDE_HOME}/settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Read(//tmp/**)",
      "Write(//tmp/**)",
      "Bash(python3:*)",
      "Bash(python:*)",
      "Bash(pip:*)",
      "Bash(curl:*)",
      "Bash(gsutil:*)",
      "Bash(gcloud:*)",
      "Bash(gcloud storage:*)",
      "Bash(cat:*)",
      "Bash(jq:*)",
      "Bash(grep:*)",
      "Bash(ls:*)",
      "Bash(date:*)",
      "Bash(wc:*)",
      "Bash(pip install:*)",
      "Bash(pip3 install:*)",
      "Bash(python -m pytest:*)",
      "Bash(python3 -m pytest:*)",
      "Bash(python -m payload_monitor:*)",
      "Bash(python3 -m payload_monitor:*)",
      "Skill(ci:*)",
      "Skill(generate-dashboard)"
    ]
  }
}
EOF
echo "Claude permissions configured."

# ---------------------------------------------------------------------------
# Set up workspace
# ---------------------------------------------------------------------------
WORKDIR=$(mktemp -d /tmp/edge-monitor-XXXXXX)
cd "${WORKDIR}"

PROW_JOB_URL=$(build_prow_url)

copy_artifacts() {
    echo "Copying artifacts to ${ARTIFACT_DIR}..."
    find "${WORKDIR}" -maxdepth 2 -name "*.html" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
    find "${WORKDIR}" -maxdepth 2 -name "*.json" \
        -not -path "*/.venv/*" -not -path "*/node_modules/*" \
        -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true

    # Archive Claude session for local continuation
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" \
            -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}
trap copy_artifacts EXIT TERM INT

# ---------------------------------------------------------------------------
# Clone and set up payload-monitor
# ---------------------------------------------------------------------------
echo "Cloning edge-tooling repository..."
git clone --depth 1 --branch main https://github.com/openshift-eng/edge-tooling.git
cd edge-tooling/payload-monitor

echo "Setting up Python environment..."
python3 -m venv .venv
source .venv/bin/activate
pip install -q -r requirements.txt

# ===========================================================================
# Phase 1: Generate dashboard (deterministic, no AI)
# ===========================================================================
echo ""
echo "=== Phase 1: Generating payload dashboard ==="

DASHBOARD_PATH="${WORKDIR}/edge-payload-dashboard.html"
JSON_PATH="${WORKDIR}/edge-payload-dashboard.json"

MONITOR_ARGS=(
    --output "${DASHBOARD_PATH}"
    --json
    --verbose
)

if [[ -n "${MONITOR_VERSIONS}" ]]; then
    MONITOR_ARGS+=(--versions "${MONITOR_VERSIONS}")
fi

if [[ "${SKIP_PROW}" == "true" ]]; then
    MONITOR_ARGS+=(--skip-prow)
fi

if [[ "${WITH_TIMING}" == "true" ]]; then
    MONITOR_ARGS+=(--with-timing)
fi

PHASE_MONITOR_START=$(date +%s)

# stdout has blocking markers, stderr has logging
python -m payload_monitor "${MONITOR_ARGS[@]}" \
    > "${WORKDIR}/monitor-stdout.txt" \
    2> >(tee "${ARTIFACT_DIR}/monitor.log" >&2) || {
    echo "Warning: Payload monitor exited with non-zero status."
}

PHASE_MONITOR_DURATION=$(( $(date +%s) - PHASE_MONITOR_START ))

# Copy initial dashboard to artifacts immediately
cp "${DASHBOARD_PATH}" "${ARTIFACT_DIR}/" 2>/dev/null || true
cp "${JSON_PATH}" "${ARTIFACT_DIR}/" 2>/dev/null || true

BLOCKING_COUNT=$(grep -c "^BLOCKING|" "${WORKDIR}/monitor-stdout.txt" 2>/dev/null || true)
BLOCKING_LIST=$(grep "^BLOCKING|" "${WORKDIR}/monitor-stdout.txt" 2>/dev/null || true)
echo "Found ${BLOCKING_COUNT} blocking job failures."

# No blocking failures — exit early
if [[ "${BLOCKING_COUNT}" -eq 0 ]]; then
    echo "No blocking failures detected across monitored topologies."
    exit 0
fi

# ===========================================================================
# Phase 2: Claude AI analysis (best-effort)
# ===========================================================================
echo ""
echo "=== Phase 2: Claude AI analysis of ${BLOCKING_COUNT} blocking failures ==="

# Workaround: --continue + -p is broken (anthropics/claude-code#42376).
export CLAUDE_CODE_ENTRYPOINT=cli

# Install marketplace plugins for CI analysis skills
echo "Installing marketplace plugins..."
claude plugin install openshift-eng/edge-tooling 2>/dev/null || echo "Warning: edge-tooling marketplace install failed."
claude plugin install openshift-eng/ai-helpers 2>/dev/null || echo "Warning: ai-helpers marketplace install failed."

ANALYSIS_JSON="${WORKDIR}/analysis.json"
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

SYSTEM_PROMPT="You are analyzing edge payload monitoring results for OpenShift nightly payloads.
You have CI analysis skills available — load them using the Skill tool before starting.
Focus on blocking job failures and identify root causes."

PHASE_ANALYSIS_START=$(date +%s)
CLAUDE_EXIT=0
timeout 3600 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 80 \
    --append-system-prompt "${SYSTEM_PROMPT}" \
    -p "Analyze the edge payload monitor results. The JSON report is at: ${JSON_PATH}

The following blocking jobs failed:
${BLOCKING_LIST}

For each blocking failure:
1. Load relevant CI skills (e.g., /ci:prow-job-analyze-test-failure)
2. Investigate the Prow job artifacts to find root causes
3. Check for existing JIRA bugs

After analysis, write a JSON file to ${ANALYSIS_JSON} mapping each prow_url to its analysis summary:
{\"<prow_url>\": \"<analysis text>\", ...}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-analysis.log" || CLAUDE_EXIT=$?

PHASE_ANALYSIS_DURATION=$(( $(date +%s) - PHASE_ANALYSIS_START ))

# Handle timeout — nudge Claude to wrap up
PHASE_NUDGE_START=$(date +%s)
NUDGE_EXIT=0
if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo ""
    echo "Claude analysis timed out. Nudging to wrap up..."
    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 10 \
        -p "Time is up. Write the analysis JSON to ${ANALYSIS_JSON} immediately with whatever findings you have." \
        --verbose 2>&1 | tee -a "${ARTIFACT_DIR}/claude-analysis.log" || NUDGE_EXIT=$?
fi
PHASE_NUDGE_DURATION=$(( $(date +%s) - PHASE_NUDGE_START ))

# ===========================================================================
# Phase 3: Merge analysis into dashboard
# ===========================================================================
if [[ -f "${ANALYSIS_JSON}" ]]; then
    echo ""
    echo "=== Phase 3: Merging AI analysis into dashboard ==="
    python -m payload_monitor \
        --merge-analysis "${ANALYSIS_JSON}" \
        --output "${DASHBOARD_PATH}" || echo "Warning: Failed to merge analysis."
    cp "${DASHBOARD_PATH}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    echo "Dashboard updated with AI analysis."
else
    echo "No analysis JSON produced. Dashboard remains without AI enrichment."
fi

# ===========================================================================
# JUnit XML for CI tracking
# ===========================================================================
TOTAL_DURATION=$(( PHASE_MONITOR_DURATION + PHASE_ANALYSIS_DURATION + PHASE_NUDGE_DURATION ))
JUNIT_FILE="${ARTIFACT_DIR}/junit_edge-monitor.xml"

PHASE_PREFIX="[sig-edge-enablement]"
PHASE_CASES="  <testcase name=\"${PHASE_PREFIX} Phase: dashboard generation\" time=\"${PHASE_MONITOR_DURATION}\"/>
  <testcase name=\"${PHASE_PREFIX} Phase: AI analysis\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"
PHASE_COUNT=2

FAILURE_COUNT=0
TIMEOUT_CASES=""
TIMEOUT_TEST_COUNT=1

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    FAILURE_COUNT=1
    TIMEOUT_CASES="  <testcase name=\"${PHASE_PREFIX} Claude should complete in a reasonable time\" time=\"${PHASE_ANALYSIS_DURATION}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
  </testcase>"

    PHASE_CASES="${PHASE_CASES}
  <testcase name=\"${PHASE_PREFIX} Phase: recovery nudge\" time=\"${PHASE_NUDGE_DURATION}\"/>"
    PHASE_COUNT=3

    if [[ "${NUDGE_EXIT}" -ne 0 ]] && [[ ! -f "${ANALYSIS_JSON}" ]]; then
        FAILURE_COUNT=2
        TIMEOUT_TEST_COUNT=2
        TIMEOUT_CASES="${TIMEOUT_CASES}
  <testcase name=\"${PHASE_PREFIX} Claude should recover after nudge\" time=\"${PHASE_NUDGE_DURATION}\">
    <failure message=\"Claude failed to recover\">Claude was nudged but did not produce analysis (exit: ${NUDGE_EXIT}).</failure>
  </testcase>"
    fi
else
    TIMEOUT_CASES="  <testcase name=\"${PHASE_PREFIX} Claude should complete in a reasonable time\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"
fi

TEST_COUNT=$(( PHASE_COUNT + TIMEOUT_TEST_COUNT ))
cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="edge-payload-monitor" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${PHASE_CASES}
${TIMEOUT_CASES}
</testsuite>
EOF

echo ""
echo "JUnit XML written to ${JUNIT_FILE}"
echo "=== Edge Payload Monitor complete ==="
