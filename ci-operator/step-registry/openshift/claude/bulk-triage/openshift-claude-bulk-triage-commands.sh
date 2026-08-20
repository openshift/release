#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
export CLAUDE_CONFIG_DIR

# --- Gangway overrides ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_VIEW:-}" ]]; then
    echo "Applying Gangway override: TRIAGE_VIEW=${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_VIEW}"
    TRIAGE_VIEW="${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_VIEW}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REPO:-}" ]]; then
    echo "Applying Gangway override: AI_HELPERS_REPO=${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REPO}"
    AI_HELPERS_REPO="${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REPO}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REF:-}" ]]; then
    echo "Applying Gangway override: AI_HELPERS_REF=${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REF}"
    AI_HELPERS_REF="${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REF}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL:-}" ]]; then
    echo "Applying Gangway override: CLAUDE_MODEL=${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL}"
    CLAUDE_MODEL="${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL}"
fi

# --- Load JIRA credentials for read-only lookups ---
# Mounted from the openshift-qse-bot-managers test-credentials secret. The
# ai-helpers skill reads JIRA_USERNAME/JIRA_API_TOKEN to look up existing bugs
# (e.g. searching OCPBUGS). JIRA access is read-only: the skill must not perform
# any JIRA writes.
# Disable tracing so the token is never echoed into the CI logs.
set +x
if [[ -f "${JIRA_EMAIL_PATH:-}" && -f "${JIRA_PAT_PATH:-}" ]]; then
    export JIRA_USERNAME JIRA_API_TOKEN JIRA_URL
    JIRA_USERNAME="$(cat "${JIRA_EMAIL_PATH}")"
    JIRA_API_TOKEN="$(cat "${JIRA_PAT_PATH}")"
    JIRA_URL="${JIRA_URL:-https://redhat.atlassian.net}"
    echo "JIRA credentials loaded for read-only lookups."
else
    echo "Warning: JIRA credentials not found (JIRA_EMAIL_PATH/JIRA_PAT_PATH); JIRA lookups will be skipped."
fi

# --- Load DPCR (Sippy) bearer token for triage-record writes ---
# Mounted from the claude-bulk-triage-dpcr-token test-credentials secret (a
# service-account token from the TRT-owned sippy namespace on DPCR). Used to
# authenticate to sippy-auth.dptools.openshift.org for creating/updating triage
# records and the reevaluate symptom probe. Still under 'set +x' so it is never
# echoed into the CI logs.
if [[ -f "${DPCR_TOKEN_PATH:-}" ]]; then
    export DPCR_TOKEN
    DPCR_TOKEN="$(cat "${DPCR_TOKEN_PATH}")"
    echo "DPCR bearer token loaded (Sippy triage writes enabled)."
else
    echo "Warning: DPCR token not found (DPCR_TOKEN_PATH); Sippy triage writes and the reevaluate probe will be unavailable."
fi

# --- Optional: replace the baked-in ai-helpers with a custom repo/branch ---
# The image's Claude plugin marketplace points at the /opt/ai-helpers
# directory (group-writable), so replacing its contents is sufficient.
if [[ -n "${AI_HELPERS_REPO:-}" ]]; then
    echo "Using custom ai-helpers: ${AI_HELPERS_REPO}@${AI_HELPERS_REF}"
    CUSTOM_DIR=$(mktemp -d /tmp/ai-helpers-custom-XXXXXX)
    git clone --depth 1 --branch "${AI_HELPERS_REF}" \
        "https://github.com/${AI_HELPERS_REPO}.git" "${CUSTOM_DIR}" \
        || { echo "ERROR: Failed to clone ${AI_HELPERS_REPO}@${AI_HELPERS_REF}"; exit 1; }
    if [[ ! -f "${CUSTOM_DIR}/.claude-plugin/marketplace.json" ]]; then
        echo "ERROR: ${AI_HELPERS_REPO}@${AI_HELPERS_REF} does not look like an ai-helpers checkout (missing .claude-plugin/marketplace.json)."
        exit 1
    fi
    find /opt/ai-helpers -mindepth 1 -delete
    # No -a/--preserve: /opt/ai-helpers itself is owned by another UID (we
    # only have group-write), so preserving ownership/times on it fails.
    cp -r --no-preserve=mode,ownership,timestamps "${CUSTOM_DIR}/." /opt/ai-helpers/
    rm -rf "${CUSTOM_DIR}"
    echo "Replaced /opt/ai-helpers with ${AI_HELPERS_REPO}@${AI_HELPERS_REF} ($(git -C /opt/ai-helpers rev-parse --short HEAD 2>/dev/null || echo 'unknown rev'))"
fi

if [[ -z "${TRIAGE_VIEW:-}" ]]; then
    echo "TRIAGE_VIEW not set, detecting latest OCP version from Sippy..."
    LATEST_VERSION=$(curl -sf "https://sippy.dptools.openshift.org/api/releases" | jq -r '.releases[] | select(test("^[0-9]+\\.[0-9]+$"))' | head -1)
    if [[ -z "${LATEST_VERSION}" ]]; then
        echo "ERROR: Could not determine latest OCP version from Sippy."
        exit 1
    fi
    TRIAGE_VIEW="${LATEST_VERSION}-main"
    echo "Auto-selected view: ${TRIAGE_VIEW}"
fi

# Resolve component scope. An empty value or the sentinel "all"
# (case-insensitive) means triage every component in the view: run
# list_regressions.py without a --components filter, rather than following
# the skill default of asking which components the duty covers.
TRIAGE_COMPONENTS="${TRIAGE_COMPONENTS:-}"
if [[ -z "${TRIAGE_COMPONENTS}" || "${TRIAGE_COMPONENTS,,}" == "all" ]]; then
    TRIAGE_COMPONENTS_DISPLAY="all"
    COMPONENTS_CLAUSE="ALL components in the view. Do NOT ask which components the duty covers and do NOT pass a --components filter: run list_regressions.py with only --view so every component is inventoried"
else
    TRIAGE_COMPONENTS_DISPLAY="${TRIAGE_COMPONENTS}"
    COMPONENTS_CLAUSE="components: ${TRIAGE_COMPONENTS}"
fi

echo "Starting claude bulk-triage-regressions run"
echo "View: ${TRIAGE_VIEW}"
echo "Components: ${TRIAGE_COMPONENTS_DISPLAY}"
echo "Model: ${CLAUDE_MODEL}"

# Install gcloud CLI for GCS artifact access (no root required)
echo "Installing gcloud CLI..."
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
/tmp/google-cloud-sdk/install.sh --quiet --path-update true
export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
echo "gcloud CLI installed."

WORKDIR=$(mktemp -d /tmp/claude-bulk-triage-XXXXXX)
cd "${WORKDIR}"

REPORT_FILE="triage-duty-report-${TRIAGE_VIEW}.md"

# Ensure the report and session logs are copied to artifacts even if the script exits early
copy_reports() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying reports to artifact directory..."
        find "${WORKDIR}" -maxdepth 1 -name "*.md" -exec cp {} "${ARTIFACT_DIR}/" \; || true
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

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"

# agentic-ci manages OTEL collector lifecycle per invocation; collect JSONL after each run
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

agentic_ci() {
    local agentic_args=()
    local timeout_seconds=""
    while true; do
        case "${1:-}" in
            --no-streaming) agentic_args+=("$1"); shift ;;
            --timeout) timeout_seconds="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local prompt="$1"; shift
    local cmd=(
        agentic-ci run
        --backend local
        --harness claude-code
        --model "${CLAUDE_MODEL}"
        --workdir "${WORKDIR}"
        "${agentic_args[@]+"${agentic_args[@]}"}"
        "${prompt}"
        --
        --permission-mode default
        --allowedTools "${ALLOWED_TOOLS}"
        --verbose
        "$@"
    )
    if [[ -n "${timeout_seconds}" ]]; then
        timeout "${timeout_seconds}" "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
    local rc=$?
    for f in /tmp/agentic-ci-run.*/claude-otel.jsonl; do
        [ -f "$f" ] && cat "$f" >> "${OTEL_LOG}"
    done
    rm -rf /tmp/agentic-ci-run.*
    return $rc
}

SYSTEM_PROMPT="You are a diligent senior OpenShift release engineer on Component Readiness triage duty.

**CRITICAL**: You have many ci skills at your disposal. You MUST load the relevant skills using the Skill tool BEFORE you begin any work. Do NOT improvise or guess. This applies equally to subagents: instruct every subagent to review its available skills and load the appropriate ones before beginning its investigation.

**WRITE SCOPE — READ CAREFULLY**: A DPCR Sippy bearer token is available in the environment variable \$DPCR_TOKEN. You ARE authorized to create and update Component Readiness triage records with it (via the ci:triage-regression skill — pass it as --token \"\$DPCR_TOKEN\"), and to run the authenticated reevaluate symptom probe in dry-run (detection) mode; use \$DPCR_TOKEN directly rather than running 'oc login'. You may link triage records ONLY to JIRA bugs that ALREADY EXIST. JIRA access is READ-ONLY: do NOT file new JIRA issues, comment on or transition issues, or set release blockers — recommend these in the report instead. Do NOT create or modify Sippy labels or symptoms (their creation requires human confirmation) — propose them in the report. Do NOT post anything to Slack or anywhere else. Capture every action you are not authorized to perform as a recommended action in your report."

PROMPT="Load and follow the ci:bulk-triage-regressions skill for view '${TRIAGE_VIEW}' covering ${COMPONENTS_CLAUSE}. Execute Phases 1-5 fully. You ARE authorized to create or extend Sippy triage records (use \$DPCR_TOKEN) for buckets whose root cause maps to a JIRA bug that already exists. For buckets that need a NEW JIRA bug, a release blocker, or a new Sippy symptom/label, record a recommendation in the report instead of performing the action (JIRA is read-only; symptom and blocker creation need human confirmation).

Write the complete duty report as GitHub-flavored markdown to ${WORKDIR}/${REPORT_FILE}. The report must contain: the untriaged-regression inventory table, the bucket list with member regression IDs and evidence (error signatures, failure stage, representative run links, suspect PRs), the recommended disposition per bucket (extend triage <id> / link to <JIRA> / file new bug against <component> with a draft summary), deliberately-untriaged leftovers with reasons, and cross-cutting observations. Every claim must cite artifact paths or run URLs."

PHASE_ANALYSIS_START=$(date +%s)
CLAUDE_EXIT=0
agentic_ci --timeout 10800 \
    "${PROMPT}" \
    --max-turns 250 \
    --append-system-prompt "${SYSTEM_PROMPT}" \
    || CLAUDE_EXIT=$?

# If Claude timed out (exit 124), nudge it to wrap up with a shorter timeout
PHASE_NUDGE_START=$(date +%s)
NUDGE_EXIT=0
if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo ""
    echo "Claude timed out. Nudging to wrap up..."
    agentic_ci --timeout 600 \
        "I think you got stuck and hit the timeout. Please wrap up now with whatever data you have collected so far: write the duty report to ${WORKDIR}/${REPORT_FILE} immediately, marking incomplete buckets as 'analysis incomplete (timeout)'." \
        --continue \
        --max-turns 20 \
        || NUDGE_EXIT=$?
fi
PHASE_NUDGE_DURATION=$(( $(date +%s) - PHASE_NUDGE_START ))
PHASE_ANALYSIS_DURATION=$(( $(date +%s) - PHASE_ANALYSIS_START ))

# Generate JUnit XML for timeout and phase duration tracking
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-ci.xml"
PHASE_PREFIX="[sig-claude]"
TIMEOUT_TESTCASE="${PHASE_PREFIX} Claude should complete in a reasonable time"
REPORT_TESTCASE="${PHASE_PREFIX} Claude should produce a triage duty report"

FAILURE_COUNT=0

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    if [[ "${NUDGE_EXIT}" -eq 0 ]] && [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
        TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
  </testcase>
  <testcase name=\"${TIMEOUT_TESTCASE} (recovery)\" time=\"${PHASE_NUDGE_DURATION}\"/>"
        FAILURE_COUNT=1
    else
        TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
  </testcase>
  <testcase name=\"${TIMEOUT_TESTCASE} (recovery)\" time=\"${PHASE_NUDGE_DURATION}\">
    <failure message=\"Claude failed to recover after nudge\">Claude was nudged to wrap up but did not produce a report (exit code: ${NUDGE_EXIT}).</failure>
  </testcase>"
        FAILURE_COUNT=2
    fi
    TIMEOUT_TEST_COUNT=2
else
    TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"
    TIMEOUT_TEST_COUNT=1
fi

if [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
    REPORT_CASES="  <testcase name=\"${REPORT_TESTCASE}\" time=\"0\"/>"
else
    REPORT_CASES="  <testcase name=\"${REPORT_TESTCASE}\" time=\"0\">
    <failure message=\"No report generated\">Expected markdown report ${REPORT_FILE} was not produced.</failure>
  </testcase>"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Extract session metrics (cost, tokens, duration) for BigQuery
METRICS_CASE=""
METRICS_TEST_COUNT=0
METRICS_FILE="${ARTIFACT_DIR}/claude-session-metrics-autodl.json"
if [[ -f "${EXTRACT_METRICS}" ]] && [[ -f "${OTEL_LOG}" ]]; then
    METRICS_TEST_COUNT=1
    if python3 "${EXTRACT_METRICS}" "${OTEL_LOG}" "${METRICS_FILE}"; then
        METRICS_CASE="  <testcase name=\"${PHASE_PREFIX} Session metrics extraction\" time=\"0\"/>"

        # Append authoritative session usage to the markdown report. This must
        # happen post-session: the model cannot observe its own final token
        # totals while the session is still running.
        if [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
            jq -r '.rows[0] | "
---

## Session usage

_Appended by the CI harness after the analysis session (extracted from OTEL telemetry)._

| Metric | Value |
|---|---|
| Model | \(.model) |
| Turns | \(.num_turns) |
| Tool calls | \(.total_tool_calls) |
| Subagents | \(.num_subagents) |
| Input tokens | \(.input_tokens) |
| Output tokens | \(.output_tokens) |
| Cache read tokens | \(.cache_read_input_tokens) |
| Cache creation tokens | \(.cache_creation_input_tokens) |
| Cache hit rate | \(.cache_hit_rate_pct)% |
| Total cost (USD) | \(.total_cost_usd) |
| Duration | \((.duration_ms | tonumber / 60000 * 10 | round / 10)) min |
"' "${METRICS_FILE}" >> "${WORKDIR}/${REPORT_FILE}" \
                || echo "Warning: failed to append session usage to the report."
        fi
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        METRICS_CASE="  <testcase name=\"${PHASE_PREFIX} Session metrics extraction\" time=\"0\">
    <failure message=\"Failed to extract session metrics\">extract_metrics.py exited with an error. Check the output log.</failure>
  </testcase>"
    fi
fi

TEST_COUNT=$(( TIMEOUT_TEST_COUNT + 1 + METRICS_TEST_COUNT ))
TOTAL_DURATION=$(( PHASE_ANALYSIS_DURATION + PHASE_NUDGE_DURATION ))
cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-ci" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${TIMEOUT_CASES}
${REPORT_CASES}
${METRICS_CASE}
</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
    echo "Triage analysis complete. Report: ${REPORT_FILE}"
else
    echo "ERROR: No markdown report was generated."
    exit 1
fi
