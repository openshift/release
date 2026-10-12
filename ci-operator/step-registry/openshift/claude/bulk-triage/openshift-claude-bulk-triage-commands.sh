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
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_EXISTING_ONLY:-}" ]]; then
    echo "Applying Gangway override: TRIAGE_EXISTING_ONLY=${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_EXISTING_ONLY}"
    TRIAGE_EXISTING_ONLY="${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_EXISTING_ONLY}"
fi
for var in TRIAGE_VIEWS TRIAGE_POLICY TRIAGE_WRITE_MODE TRIAGE_MODE TRIAGE_BASELINE POSTGA_ACK_RECEIPT; do
    override_var="MULTISTAGE_PARAM_OVERRIDE_${var}"
    if [[ -n "${!override_var:-}" ]]; then
        echo "Applying Gangway override: ${var}=${!override_var}"
        printf -v "${var}" '%s' "${!override_var}"
    fi
done

# --- Post-GA policy knobs (defaults keep the historical duty behaviour) ---
TRIAGE_POLICY="${TRIAGE_POLICY:-duty}"
TRIAGE_WRITE_MODE="${TRIAGE_WRITE_MODE:-auto}"
TRIAGE_MODE="${TRIAGE_MODE:-weekly}"
TRIAGE_BASELINE="${TRIAGE_BASELINE:-auto}"
TRIAGE_VIEWS="${TRIAGE_VIEWS:-}"
POSTGA_ACK_RECEIPT="${POSTGA_ACK_RECEIPT:-}"
# Where the ai-helpers bulk-triage scripts live (overridable for rehearsal from a checkout).
AIH_SCRIPTS_DIR="${AIH_SCRIPTS_DIR:-/opt/ai-helpers/plugins/ci/skills/bulk-triage-regressions/scripts}"
# Optional local inventory for the pre-pass (testing/rehearsal only; skips Sippy and the oracle).
TRIAGE_INVENTORY_FILE="${TRIAGE_INVENTORY_FILE:-}"
GCS_BUCKET="${GCS_BUCKET:-test-platform-results}"
RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    # post-ga is existing-only by definition (spec §6.1); never file new JIRA issues.
    TRIAGE_EXISTING_ONLY="true"
fi

# --- Load JIRA credentials (read + write) ---
# Mounted from the openshift-qse-bot-managers test-credentials secret. The
# ai-helpers skill uses JIRA_USERNAME/JIRA_API_TOKEN both to look up existing
# bugs and to write as the openshift-qse-bot-managers service account (append
# triage links, comment, file new bugs).
# Disable tracing so the token is never echoed into the CI logs.
set +x
if [[ -f "${JIRA_EMAIL_PATH:-}" && -f "${JIRA_PAT_PATH:-}" ]]; then
    export JIRA_USERNAME JIRA_API_TOKEN JIRA_URL
    JIRA_USERNAME="$(cat "${JIRA_EMAIL_PATH}")"
    JIRA_API_TOKEN="$(cat "${JIRA_PAT_PATH}")"
    JIRA_URL="${JIRA_URL:-https://redhat.atlassian.net}"
    echo "JIRA credentials loaded (read + write)."
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
if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    # The agent gets the loaded values only, never the mount paths.
    unset JIRA_EMAIL_PATH JIRA_PAT_PATH DPCR_TOKEN_PATH
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

if [[ -n "${TRIAGE_VIEWS}" ]]; then
    # Multi-view run (post-GA): the first view keeps legacy single-view variables meaningful.
    TRIAGE_VIEW="${TRIAGE_VIEWS%% *}"
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
TRIAGE_VIEWS="${TRIAGE_VIEWS:-${TRIAGE_VIEW}}"

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
if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    echo "Views: ${TRIAGE_VIEWS}"
    echo "Policy: post-ga (mode ${TRIAGE_MODE}, write-mode ${TRIAGE_WRITE_MODE}, baseline ${TRIAGE_BASELINE})"
else
    echo "View: ${TRIAGE_VIEW}"
fi
echo "Components: ${TRIAGE_COMPONENTS_DISPLAY}"
echo "Model: ${CLAUDE_MODEL}"

# Existing-only mode: pass --existing-only to the skill and narrow the JIRA
# write scope to matches against existing issues (no new bugs).
EXISTING_ONLY_FLAG=""
JIRA_WRITE_SCOPE="and ARE authorized to file new bugs (/jira:create bug against the OWNING component, label component-regression), comment on existing issues, and run ci:add-jira-triage-link after each triage."
JIRA_BUG_SCOPE="to file new JIRA bugs against the owning component for buckets with no existing bug, "
EXISTING_ONLY_REPORT=""
if [[ "${TRIAGE_EXISTING_ONLY:-false}" == "true" ]]; then
    EXISTING_ONLY_FLAG=" with --existing-only"
    JIRA_WRITE_SCOPE="and ARE authorized, only for a verified match to an existing issue, to comment on that issue and run ci:add-jira-triage-link after each triage. You are NOT authorized to create, reopen, or transition JIRA issues: every bucket that needs a new bug goes in the report as a draft under 'Proposed new bugs (not filed)'."
    JIRA_BUG_SCOPE=""
    EXISTING_ONLY_REPORT=" Because --existing-only is set, do NOT file any JIRA issue; the report must also contain the 'Proposed new bugs (not filed)' section (even if empty)."
fi
echo "Existing-only: ${TRIAGE_EXISTING_ONLY:-false}"

# Install gcloud CLI for GCS artifact access (no root required)
echo "Installing gcloud CLI..."
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
/tmp/google-cloud-sdk/install.sh --quiet --path-update true
export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
echo "gcloud CLI installed."

WORKDIR=$(mktemp -d /tmp/claude-bulk-triage-XXXXXX)
cd "${WORKDIR}"

REPORT_FILE="triage-duty-report-${TRIAGE_VIEW}.md"
if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    REPORT_FILE="triage-duty-report-post-ga.md"
fi

# --- Post-GA helpers: job history, pre-pass, audit, receipt, junit ---
JUNIT_EXTRA_CASES=""
JUNIT_EXTRA_COUNT=0
JUNIT_EXTRA_FAILURES=0
junit_case() {
    # junit_case <name> <ok:true|false> <message>
    JUNIT_EXTRA_COUNT=$(( JUNIT_EXTRA_COUNT + 1 ))
    if [[ "$2" == "true" ]]; then
        JUNIT_EXTRA_CASES+="  <testcase name=\"[sig-claude] $1\" time=\"0\"/>
"
    else
        JUNIT_EXTRA_FAILURES=$(( JUNIT_EXTRA_FAILURES + 1 ))
        JUNIT_EXTRA_CASES+="  <testcase name=\"[sig-claude] $1\" time=\"0\">
    <failure message=\"$3\">$3</failure>
  </testcase>
"
    fi
}

latest_preceding_attempt() {
    # Prints the greatest run id of this job in GCS that is not the current build, or nothing.
    local prefix="gs://${GCS_BUCKET}/logs/${JOB_NAME:-}/"
    gcloud storage ls "${prefix}" 2>/dev/null \
        | sed -E 's#/+$##; s#.*/##' \
        | grep -E '^[0-9]+$' \
        | grep -vx "${BUILD_ID:-0}" \
        | sort -n | tail -1 || true
}

fetch_prev_artifact() {
    # fetch_prev_artifact <run-id> <artifact-name> <dest>; non-zero when absent.
    local run="$1" name="$2" dest="$3"
    gcloud storage cp \
        "gs://${GCS_BUCKET}/logs/${JOB_NAME:-}/${run}/artifacts/*/openshift-claude-bulk-triage/artifacts/${name}" \
        "${dest}" >/dev/null 2>&1
}

write_extra_junit_and_exit() {
    # Used by tripwire mode, which never reaches the agent/junit section below.
    local failures="${JUNIT_EXTRA_FAILURES}"
    cat > "${ARTIFACT_DIR}/junit_claude-ci.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-ci" tests="${JUNIT_EXTRA_COUNT}" failures="${failures}" time="0">
${JUNIT_EXTRA_CASES}</testsuite>
EOF
    echo "JUnit XML written to ${ARTIFACT_DIR}/junit_claude-ci.xml"
    if [[ "${failures}" -gt 0 ]]; then exit 1; fi
    exit 0
}

PREPASS_INVENTORY_ARGS=()
if [[ -n "${TRIAGE_INVENTORY_FILE}" ]]; then
    PREPASS_INVENTORY_ARGS=(--inventory "${TRIAGE_INVENTORY_FILE}" --no-oracle)
fi

if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    PREV_RUN=""
    if [[ "${TRIAGE_BASELINE}" == "auto" ]]; then
        PREV_RUN="$(latest_preceding_attempt)"
        if [[ -z "${PREV_RUN}" ]]; then
            echo "No preceding attempt found in gs://${GCS_BUCKET}/logs/${JOB_NAME:-} (or job history unreadable); baseline none."
        else
            echo "Latest preceding attempt: ${PREV_RUN}"
        fi
    fi
    # shellcheck disable=SC2086
    read -r -a TRIAGE_VIEWS_ARR <<< "${TRIAGE_VIEWS}"
fi

if [[ "${TRIAGE_POLICY}" == "post-ga" && "${TRIAGE_MODE}" == "tripwire" ]]; then
    echo "Tripwire mode: deterministic pre-pass over the last 24h, no LLM call, no writes."
    PREV_STATUS_ARG="none"
    if [[ -n "${PREV_RUN}" ]] && fetch_prev_artifact "${PREV_RUN}" burst-status.json "${WORKDIR}/previous-burst-status.json"; then
        PREV_STATUS_ARG="${WORKDIR}/previous-burst-status.json"
    fi
    echo "Previous status: ${PREV_STATUS_ARG}"
    TRIPWIRE_OK=true
    python3 "${AIH_SCRIPTS_DIR}/prepass.py" --tripwire --views "${TRIAGE_VIEWS_ARR[@]}" \
        --window-hours 24 --previous-status "${PREV_STATUS_ARG}" --run-id "${BUILD_ID:-local}" \
        ${PREPASS_INVENTORY_ARGS[@]+"${PREPASS_INVENTORY_ARGS[@]}"} --out "${ARTIFACT_DIR}/burst-status.json" || TRIPWIRE_OK=false
    if [[ "${TRIPWIRE_OK}" == "true" && -s "${ARTIFACT_DIR}/burst-status.json" ]]; then
        junit_case "tripwire: burst-status.json produced" true ""
        echo "Tripwire triggers: $(jq -r '.triggers | length' "${ARTIFACT_DIR}/burst-status.json" 2>/dev/null || echo unknown)"
    else
        junit_case "tripwire: burst-status.json produced" false "prepass.py --tripwire failed or produced no output"
    fi
    write_extra_junit_and_exit
fi

MODE_EFFECTIVE="${TRIAGE_WRITE_MODE}"
MODE_REASON=""
BASELINE_ARG="none"
if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    # Receipt check: the latest preceding attempt's audit can force report mode.
    RECEIPT_PATH=""
    if [[ -n "${PREV_RUN}" ]] && fetch_prev_artifact "${PREV_RUN}" runner-receipt.json "${WORKDIR}/previous-receipt.json"; then
        RECEIPT_PATH="${WORKDIR}/previous-receipt.json"
    fi
    DECIDE_ARGS=(receipt-decide)
    if [[ -n "${RECEIPT_PATH}" ]]; then DECIDE_ARGS+=(--receipt "${RECEIPT_PATH}"); else DECIDE_ARGS+=(--receipt /nonexistent/runner-receipt.json); fi
    if [[ -n "${POSTGA_ACK_RECEIPT}" ]]; then DECIDE_ARGS+=(--ack "${POSTGA_ACK_RECEIPT}"); fi
    DECISION_LINE="$(python3 "${AIH_SCRIPTS_DIR}/audit.py" "${DECIDE_ARGS[@]}" 2>/dev/null || printf 'report\treceipt-decide failed')"
    DECISION="${DECISION_LINE%%$'\t'*}"
    MODE_REASON="${DECISION_LINE#*$'\t'}"
    if [[ "${DECISION}" == "report" ]]; then
        MODE_EFFECTIVE="report"
        echo "Write mode forced to report by the previous receipt: ${MODE_REASON}"
    elif [[ -n "${MODE_REASON}" ]]; then
        echo "Receipt decision: ${MODE_REASON}"
    elif [[ "${TRIAGE_WRITE_MODE}" == "report" ]]; then
        MODE_REASON="configured"
    fi
    echo "Effective write mode: ${MODE_EFFECTIVE} (requested ${TRIAGE_WRITE_MODE})"

    if [[ -n "${PREV_RUN}" ]] && fetch_prev_artifact "${PREV_RUN}" triage-manifest.json "${WORKDIR}/baseline-manifest.json"; then
        BASELINE_ARG="${WORKDIR}/baseline-manifest.json"
    fi
    echo "Baseline: ${BASELINE_ARG}"

    # Sippy triage catalogue before the agent runs (authoritative record of Sippy writes).
    python3 "${AIH_SCRIPTS_DIR}/audit.py" snapshot --out "${ARTIFACT_DIR}/sippy-triages-before.json" || true

    echo "Running the deterministic pre-pass..."
    PREPASS_OK=true
    python3 "${AIH_SCRIPTS_DIR}/prepass.py" --views "${TRIAGE_VIEWS_ARR[@]}" --baseline "${BASELINE_ARG}" \
        --token-env DPCR_TOKEN --run-id "${BUILD_ID:-local}" ${PREPASS_INVENTORY_ARGS[@]+"${PREPASS_INVENTORY_ARGS[@]}"} \
        --out "${WORKDIR}/prepass.json" || PREPASS_OK=false
    if [[ "${PREPASS_OK}" == "true" && -s "${WORKDIR}/prepass.json" ]]; then
        cp "${WORKDIR}/prepass.json" "${ARTIFACT_DIR}/prepass.json"
        junit_case "post-GA: pre-pass produced prepass.json" true ""
        echo "Pre-pass clusters: $(jq -r '.clusters | length' "${WORKDIR}/prepass.json" 2>/dev/null || echo unknown)"
    else
        junit_case "post-GA: pre-pass produced prepass.json" false "prepass.py failed; the agent cannot run without an inventory"
        write_extra_junit_and_exit
    fi
fi

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

**WRITE SCOPE — READ CAREFULLY**: You have write credentials for both Sippy and JIRA. Sippy: a DPCR bearer token is in the environment variable \$DPCR_TOKEN — you ARE authorized to create and update Component Readiness triage records (via the ci:triage-regression skill — pass it as --token \"\$DPCR_TOKEN\") and to run the authenticated reevaluate symptom probe in dry-run (detection) mode; use \$DPCR_TOKEN directly rather than running 'oc login'. JIRA: you act as the openshift-qse-bot-managers service account (\$JIRA_USERNAME / \$JIRA_API_TOKEN) ${JIRA_WRITE_SCOPE} Every JIRA issue or comment you create MUST end with the AI-attribution footer as its own visually marked block (an ADF rule followed by a note panel containing 'AI-generated content: filed by AI as part of Component Readiness triage duty. Please verify before acting on it.'); after add-jira-triage-link runs, verify that footer is still the final block. You are NOT authorized to: transition, resolve, or close JIRA issues; set release blockers; or create/modify Sippy labels or symptoms — capture each of those as a recommendation in the report. Do NOT post anything to Slack or anywhere else."

PROMPT="Load and follow the ci:bulk-triage-regressions skill for view '${TRIAGE_VIEW}' covering ${COMPONENTS_CLAUSE}. Execute Phases 1-5 fully${EXISTING_ONLY_FLAG}. You ARE authorized to create or extend Sippy triage records (use \$DPCR_TOKEN), ${JIRA_BUG_SCOPE}to comment on existing bugs, and to append the Component Readiness triage link to each bug (ci:add-jira-triage-link) — every JIRA issue or comment you create must carry the AI-attribution footer. Record a recommendation in the report instead of performing the action for: release blockers, new Sippy symptoms/labels, and any JIRA transition/resolve/close (these need human confirmation).

Write the complete duty report as GitHub-flavored markdown to ${WORKDIR}/${REPORT_FILE}. The report must contain: the untriaged-regression inventory table, the bucket list with member regression IDs and evidence (error signatures, failure stage, representative run links, suspect PRs), the recommended disposition per bucket (extend triage <id> / link to <JIRA> / file new bug against <component> with a draft summary), deliberately-untriaged leftovers with reasons, and cross-cutting observations. Every claim must cite artifact paths or run URLs.${EXISTING_ONLY_REPORT}"

if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    POSTGA_WRITE_CLAUSE="You ARE authorized, in --write-mode auto, to create or extend Sippy triage records (use \$DPCR_TOKEN) and to perform the JIRA writes allowed by references/post-ga-policy.md (ci:add-jira-triage-link and the backport-candidate comment) — and nothing else."
    if [[ "${MODE_EFFECTIVE}" == "report" ]]; then
        POSTGA_WRITE_CLAUSE="This run is --write-mode report: you are NOT authorized to perform ANY write to Sippy or JIRA (no triage records, no triage links, no comments). Record every intended action in the manifest with status skipped-report-mode."
    fi
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

**POST-GA POLICY**: This is a post-GA (released versions) run under --policy post-ga --write-mode ${MODE_EFFECTIVE}. ${POSTGA_WRITE_CLAUSE} Phase 0 is already done by the runner: ${WORKDIR}/prepass.json is the complete inventory and cluster list — do not re-derive clusters and do not call the Sippy list/details/related-triages APIs for inventory. Analyse clusters in file order (HIGH first) under the time budget. A symptom_probe.status other than ok is UNKNOWN, never 'no symptoms matched'. Follow references/post-ga-policy.md for everything else."

    PROMPT="Load and follow the ci:bulk-triage-regressions skill with --policy post-ga --write-mode ${MODE_EFFECTIVE} --views ${TRIAGE_VIEWS} covering ${COMPONENTS_CLAUSE}, with --existing-only. Phase 0 is complete: read ${WORKDIR}/prepass.json and treat its clusters as the batch. Execute Phases 1-5 per references/post-ga-policy.md. ${POSTGA_WRITE_CLAUSE}

Write ${WORKDIR}/triage-manifest.json by assembling dispositions.json, actions.json and extra.json as the policy describes and running ${AIH_SCRIPTS_DIR}/manifest.py merge --prepass ${WORKDIR}/prepass.json ... --out ${WORKDIR}/triage-manifest.json, then ${AIH_SCRIPTS_DIR}/manifest.py validate ${WORKDIR}/triage-manifest.json (it must exit 0; fix the data, never weaken it). Write the complete duty report as GitHub-flavored markdown to ${WORKDIR}/${REPORT_FILE}: inventory per view, every cluster with its blast radius, disposition, evidence (own run links, artifact paths), bug decisions and action or proposed action, the watch list, catch-all admissions, backport candidates, unanalysed clusters, and cross-cutting observations. Every claim must cite artifact paths or run URLs.${EXISTING_ONLY_REPORT}"
fi

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

if [[ "${TRIAGE_POLICY}" == "post-ga" ]]; then
    RUN_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Manifest: copy and validate.
    if [[ -s "${WORKDIR}/triage-manifest.json" ]]; then
        cp "${WORKDIR}/triage-manifest.json" "${ARTIFACT_DIR}/triage-manifest.json"
        if python3 "${AIH_SCRIPTS_DIR}/manifest.py" validate "${WORKDIR}/triage-manifest.json" 2> "${WORKDIR}/manifest-validate.err"; then
            junit_case "post-GA: manifest validates" true ""
        else
            junit_case "post-GA: manifest validates" false "manifest.py validate failed: $(head -c 400 "${WORKDIR}/manifest-validate.err" | tr '"<>&' "'   ")"
        fi
    else
        junit_case "post-GA: manifest validates" false "triage-manifest.json was not produced"
    fi
    # Sippy triage catalogue after the agent; diff against the declared actions.
    python3 "${AIH_SCRIPTS_DIR}/audit.py" snapshot --out "${ARTIFACT_DIR}/sippy-triages-after.json" || true
    SIPPY_DIFF_STATUS="unknown"
    if [[ -s "${ARTIFACT_DIR}/sippy-triages-before.json" && -s "${ARTIFACT_DIR}/sippy-triages-after.json" ]]; then
        MANIFEST_FOR_DIFF="${ARTIFACT_DIR}/triage-manifest.json"
        [[ -s "${MANIFEST_FOR_DIFF}" ]] || MANIFEST_FOR_DIFF="/dev/null"
        SIPPY_DIFF_STATUS="$(python3 "${AIH_SCRIPTS_DIR}/audit.py" diff --before "${ARTIFACT_DIR}/sippy-triages-before.json" \
            --after "${ARTIFACT_DIR}/sippy-triages-after.json" --manifest "${MANIFEST_FOR_DIFF}" \
            --out "${ARTIFACT_DIR}/sippy-catalog-diff.json" 2>/dev/null || echo unknown)"
    fi
    if [[ ! -s "${ARTIFACT_DIR}/sippy-catalog-diff.json" ]]; then
        printf '{"status": "unknown", "error": "catalogue snapshots missing or diff failed"}\n' > "${ARTIFACT_DIR}/sippy-catalog-diff.json"
    fi
    if [[ "${SIPPY_DIFF_STATUS}" == "match" ]]; then
        junit_case "post-GA: Sippy writes match the report" true ""
    else
        junit_case "post-GA: Sippy writes match the report" false "Sippy catalogue diff status: ${SIPPY_DIFF_STATUS}"
    fi
    # Account-wide JIRA creations in the run window (shared service account: attribution is best-effort).
    python3 "${AIH_SCRIPTS_DIR}/audit.py" jql --start "${RUN_START}" --end "${RUN_END}" \
        --reporter "${JIRA_USERNAME:-unknown}" --out "${ARTIFACT_DIR}/jira-creations.json" || true
    JIRA_CREATED="$(jq -r '.count // "unknown"' "${ARTIFACT_DIR}/jira-creations.json" 2>/dev/null || echo unknown)"
    JIRA_STATUS="$(jq -r '.status // "unknown"' "${ARTIFACT_DIR}/jira-creations.json" 2>/dev/null || echo unknown)"
    if [[ "${JIRA_STATUS}" == "ok" && "${JIRA_CREATED}" == "0" ]]; then
        junit_case "post-GA: no Jira issues created by the job" true ""
    else
        junit_case "post-GA: no Jira issues created by the job" false "account-wide creations in window: ${JIRA_CREATED} (status ${JIRA_STATUS}; shared account — see jira-creations.json)"
    fi
    echo "Jira creations in window (account-wide): ${JIRA_CREATED} (status ${JIRA_STATUS}); Sippy diff: ${SIPPY_DIFF_STATUS}"
    # Receipt for the next run.
    if python3 "${AIH_SCRIPTS_DIR}/audit.py" receipt-write --out "${ARTIFACT_DIR}/runner-receipt.json" \
        --run-id "${BUILD_ID:-local}" --mode-requested "${TRIAGE_WRITE_MODE}" --mode-effective "${MODE_EFFECTIVE}" \
        --jira-creations "${ARTIFACT_DIR}/jira-creations.json" \
        --sippy-diff "${ARTIFACT_DIR}/sippy-catalog-diff.json" \
        ${PREV_RUN:+--previous-run "${PREV_RUN}"}; then
        junit_case "post-GA: receipt written" true ""
    else
        junit_case "post-GA: receipt written" false "audit.py receipt-write failed"
    fi
fi

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

TEST_COUNT=$(( TIMEOUT_TEST_COUNT + 1 + METRICS_TEST_COUNT + JUNIT_EXTRA_COUNT ))
FAILURE_COUNT=$(( FAILURE_COUNT + JUNIT_EXTRA_FAILURES ))
TOTAL_DURATION=$(( PHASE_ANALYSIS_DURATION + PHASE_NUDGE_DURATION ))
cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-ci" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${TIMEOUT_CASES}
${REPORT_CASES}
${METRICS_CASE}
${JUNIT_EXTRA_CASES}</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
    echo "Triage analysis complete. Report: ${REPORT_FILE}"
else
    echo "ERROR: No markdown report was generated."
    exit 1
fi
