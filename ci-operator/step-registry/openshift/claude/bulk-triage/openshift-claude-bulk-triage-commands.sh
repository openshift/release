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

echo "Starting claude bulk-triage dry run"
echo "View: ${TRIAGE_VIEW}"
echo "Components: ${TRIAGE_COMPONENTS}"
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

**THIS IS A DRY RUN — READ-ONLY MODE**: You must NOT perform any write operations of any kind. Do not create or update triage records, do not file or comment on JIRA issues, do not set release blockers, do not create Sippy labels or symptoms, do not apply retroactive re-evaluation, and do not post anything anywhere. You have no write credentials; every write step of the skill must instead be captured as a recommended action in your report."

PROMPT="Load and follow the ci:bulk-triage-regressions skill for view '${TRIAGE_VIEW}' with components: ${TRIAGE_COMPONENTS}. Execute Phases 1-3 and the analysis parts of Phase 4-5 fully, but perform NO writes (dry run): every action the skill would take (extend triage, new triage, new bug, symptom label) must be recorded as a recommendation instead.

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
    echo "Dry-run triage analysis complete. Report: ${REPORT_FILE}"
else
    echo "ERROR: No markdown report was generated."
    exit 1
fi
