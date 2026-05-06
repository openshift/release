#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== Edge Enablement CI Monitor ==="
echo "Started at $(date -u '+%Y-%m-%d %H:%M UTC')"

# ---------------------------------------------------------------------------
# Load secrets (xtrace disabled to prevent leaking credentials in logs)
# ---------------------------------------------------------------------------
set +x

if [[ -f "${GITHUB_APP_ID_PATH}" ]] && [[ -f "${GITHUB_KEY_PATH}" ]]; then
    GH_TOKEN_VER="2.0.8"
    GH_TOKEN_SHA="867d9ebf7dd18e67e2599f0f890f3f41b8673e88c4394a32a05476024c41ea0f"
    GH_TOKEN_EXE="/tmp/gh-token-${GH_TOKEN_VER}"

    curl -sSL --connect-timeout 10 --max-time 30 --fail "https://github.com/Link-/gh-token/releases/download/v${GH_TOKEN_VER}/linux-amd64" -o "${GH_TOKEN_EXE}"
    if ! echo "${GH_TOKEN_SHA}  ${GH_TOKEN_EXE}" | sha256sum -c -; then
        echo "ERROR: Failed to verify gh-token checksum."
        exit 1
    fi
    chmod +x "${GH_TOKEN_EXE}"

    GITHUB_TOKEN="$("${GH_TOKEN_EXE}" generate --app-id "$(< "${GITHUB_APP_ID_PATH}")" --key "${GITHUB_KEY_PATH}" | jq -r '.token')"
    rm -f "${GH_TOKEN_EXE}"
    if [[ -z "${GITHUB_TOKEN}" ]] || [[ "${GITHUB_TOKEN}" == "null" ]]; then
        echo "ERROR: Failed to generate GitHub token from App credentials."
        exit 1
    fi
    export GITHUB_TOKEN
    echo "GitHub token generated."
else
    echo "ERROR: GitHub App credentials not found. Cannot clone edge-tooling."
    exit 1
fi

if [[ -f "${JIRA_API_TOKEN_PATH}" ]]; then
    export JIRA_TOKEN
    JIRA_TOKEN=$(cat "${JIRA_API_TOKEN_PATH}")
    echo "JIRA token loaded."
fi

if [[ -f "${JIRA_USERNAME_PATH}" ]]; then
    export JIRA_USERNAME
    JIRA_USERNAME=$(cat "${JIRA_USERNAME_PATH}")
    echo "JIRA username loaded."
fi

# ---------------------------------------------------------------------------
# Install gcloud CLI for Prow artifact access (no root required)
# ---------------------------------------------------------------------------
GCLOUD_VER="565.0.0"
GCLOUD_SHA="733e3640b5892baecd997474cb1b2cfe80204b6584c64166c3d78bae3f1108c3"
GCLOUD_TGZ="/tmp/google-cloud-cli.tar.gz"

echo "Installing gcloud CLI ${GCLOUD_VER}..."
curl -sSL --connect-timeout 10 --max-time 300 --fail \
    "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VER}-linux-x86_64.tar.gz" \
    -o "${GCLOUD_TGZ}"
if ! echo "${GCLOUD_SHA}  ${GCLOUD_TGZ}" | sha256sum -c -; then
    echo "ERROR: Failed to verify gcloud CLI checksum."
    exit 1
fi
tar -xzf "${GCLOUD_TGZ}" -C /tmp
rm -f "${GCLOUD_TGZ}"
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
      "Skill(edge-ocp-ci:*)"
    ]
  }
}
EOF
echo "Claude permissions configured."

# ---------------------------------------------------------------------------
# Set up workspace
# ---------------------------------------------------------------------------
WORKDIR=$(mktemp -d /tmp/ci-monitor-XXXXXX)
cd "${WORKDIR}"

copy_artifacts() {
    echo "Copying artifacts to ${ARTIFACT_DIR}..."
    local report_dir="${WORKDIR}/edge-tooling/payload-monitor/reports"
    if [[ -d "${report_dir}" ]]; then
        local latest_html
        latest_html=$(ls -t "${report_dir}"/*.html 2>/dev/null | head -1)
        if [[ -n "${latest_html}" ]]; then
            cp "${latest_html}" "${ARTIFACT_DIR}/edge-ci-monitor-summary.html"
        fi
        cp "${report_dir}"/*.json "${ARTIFACT_DIR}/" 2>/dev/null || true
    fi

    # Extract blocking/informing job summaries into a single file for
    # downstream steps.  Each line is prefixed BLOCKING| or INFORMING|.
    # SHARED_DIR is backed by a K8s Secret (1 MB limit) so only the
    # extracted data is shared — not the full multi-MB stream-JSON log.
    if [[ -r "${ARTIFACT_DIR}/claude-analysis.log" ]]; then
        {
            sed -n '/BLOCKING_JOBS_START/,/BLOCKING_JOBS_END/p' "${ARTIFACT_DIR}/claude-analysis.log" \
                | grep -oE 'BLOCKING\|[^|]+\|https://[^|]+\|[^|]+\|[0-9]+\.[0-9]+\|[^|"\\]+'
            sed -n '/INFORMING_JOBS_START/,/INFORMING_JOBS_END/p' "${ARTIFACT_DIR}/claude-analysis.log" \
                | grep -oE 'INFORMING\|[^|]+\|https://[^|]+\|[^|]+\|[0-9]+\.[0-9]+\|[^|"\\]+'
        } | sort -u > "${SHARED_DIR}/failing-jobs.txt" || true
    fi

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
# Clone edge-tooling (needed for payload-monitor tool and plugin skills)
# ---------------------------------------------------------------------------
echo "Cloning edge-tooling repository..."
gh repo clone openshift-eng/edge-tooling edge-tooling -- --depth 1 --branch main

# ---------------------------------------------------------------------------
# Register local marketplaces and install plugins
# ---------------------------------------------------------------------------
# Workaround: --continue + -p is broken (anthropics/claude-code#42376).
export CLAUDE_CODE_ENTRYPOINT=cli

echo "Cloning ai-helpers for CI analysis skills..."
gh repo clone openshift-eng/ai-helpers ai-helpers -- --depth 1 --branch main

echo "Registering local marketplaces..."
claude plugin marketplace add "${WORKDIR}/edge-tooling"
claude plugin marketplace add "${WORKDIR}/ai-helpers"

echo "Installing plugins..."
claude plugin install edge-ocp-ci
claude plugin install ci

# ---------------------------------------------------------------------------
# Build skill arguments from env vars
# ---------------------------------------------------------------------------
SKILL_ARGS=""
if [[ -n "${MONITOR_VERSIONS}" ]]; then
    SKILL_ARGS+="--versions ${MONITOR_VERSIONS} "
fi
if [[ "${SKIP_PROW}" == "true" ]]; then
    SKILL_ARGS+="--skip-prow "
fi
if [[ "${WITH_TIMING}" == "true" ]]; then
    SKILL_ARGS+="--with-timing "
fi
if [[ -n "${PAYLOAD_COUNT}" ]]; then
    SKILL_ARGS+="--payloads ${PAYLOAD_COUNT} "
fi

# ===========================================================================
# Invoke Claude with the generate-dashboard skill
# ===========================================================================
echo ""
echo "=== Invoking Claude with edge-ocp-ci:generate-dashboard ==="

ALLOWED_TOOLS="Agent SendMessage Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

PHASE_START=$(date +%s)
CLAUDE_EXIT=0
timeout 7200 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 150 \
    -p "/edge-ocp-ci:generate-dashboard ${SKILL_ARGS}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-analysis.log" || CLAUDE_EXIT=$?

PHASE_DURATION=$(( $(date +%s) - PHASE_START ))

# Handle timeout — nudge Claude to wrap up
PHASE_NUDGE_START=$(date +%s)
NUDGE_EXIT=0
if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo ""
    echo "Claude timed out. Nudging to wrap up..."
    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 15 \
        -p "Time is up. Write whatever analysis you have to the JSON file now (Step 5), then merge into the dashboard (Step 6)." \
        --verbose 2>&1 | tee -a "${ARTIFACT_DIR}/claude-analysis.log" || NUDGE_EXIT=$?
fi
PHASE_NUDGE_DURATION=$(( $(date +%s) - PHASE_NUDGE_START ))

# ===========================================================================
# JUnit XML for CI tracking
# ===========================================================================
TOTAL_DURATION=$(( PHASE_DURATION + PHASE_NUDGE_DURATION ))
JUNIT_FILE="${ARTIFACT_DIR}/junit_ci-monitor.xml"

PHASE_PREFIX="[sig-edge-enablement]"
PHASE_CASES="  <testcase name=\"${PHASE_PREFIX} CI monitor\" time=\"${PHASE_DURATION}\"/>"
PHASE_COUNT=1

FAILURE_COUNT=0
TIMEOUT_CASES=""
TIMEOUT_TEST_COUNT=1

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    FAILURE_COUNT=1
    TIMEOUT_CASES="  <testcase name=\"${PHASE_PREFIX} Claude should complete in a reasonable time\" time=\"${PHASE_DURATION}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
  </testcase>"

    PHASE_CASES="${PHASE_CASES}
  <testcase name=\"${PHASE_PREFIX} Recovery nudge\" time=\"${PHASE_NUDGE_DURATION}\"/>"
    PHASE_COUNT=2

    if [[ "${NUDGE_EXIT}" -ne 0 ]]; then
        FAILURE_COUNT=2
        TIMEOUT_TEST_COUNT=2
        TIMEOUT_CASES="${TIMEOUT_CASES}
  <testcase name=\"${PHASE_PREFIX} Claude should recover after nudge\" time=\"${PHASE_NUDGE_DURATION}\">
    <failure message=\"Claude failed to recover\">Claude was nudged but did not produce analysis (exit: ${NUDGE_EXIT}).</failure>
  </testcase>"
    fi
elif [[ "${CLAUDE_EXIT}" -ne 0 ]]; then
    FAILURE_COUNT=1
    TIMEOUT_CASES="  <testcase name=\"${PHASE_PREFIX} Claude should complete successfully\" time=\"${PHASE_DURATION}\">
    <failure message=\"Claude exited with code ${CLAUDE_EXIT}\">Claude failed with exit code ${CLAUDE_EXIT}.</failure>
  </testcase>"
else
    TIMEOUT_CASES="  <testcase name=\"${PHASE_PREFIX} Claude should complete in a reasonable time\" time=\"${PHASE_DURATION}\"/>"
fi

TEST_COUNT=$(( PHASE_COUNT + TIMEOUT_TEST_COUNT ))
cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="edge-ci-monitor" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${PHASE_CASES}
${TIMEOUT_CASES}
</testsuite>
EOF

echo ""
echo "JUnit XML written to ${JUNIT_FILE}"
touch "${SHARED_DIR}/monitor-completed"
echo "=== Edge CI Monitor complete ==="
