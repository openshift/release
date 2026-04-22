#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Read webhook URL (tracing disabled — secret handling)
# ---------------------------------------------------------------------------
WEBHOOK_URL=$(cat /var/run/slack-webhook/ocp-ci-monitor)

# ---------------------------------------------------------------------------
# Build URLs
# ---------------------------------------------------------------------------
JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
GCS_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
DASHBOARD_URL="${GCS_BASE}/logs/${JOB_NAME}/${BUILD_ID}/artifacts/ocp-ci-monitor/openshift-edge-tooling-ci-monitor/artifacts/edge-ci-monitor-summary.html"

# ---------------------------------------------------------------------------
# Extract blocking jobs from the analysis log
#
# Format between BLOCKING_JOBS_START/END:
#   BLOCKING|<job_name>|<prow_url>|<topology>|<version>|<payload>
# ---------------------------------------------------------------------------
LOG_FILE="${SHARED_DIR}/claude-analysis.log"

BLOCKING_COUNT=0
VERSIONS=""
TOPOLOGIES=""
DATA_AVAILABLE=false

if [[ -f "${LOG_FILE}" ]]; then
    BLOCKING_LINES=$(sed -n '/BLOCKING_JOBS_START/,/BLOCKING_JOBS_END/p' "${LOG_FILE}" \
        | { grep -v 'BLOCKING_JOBS_START\|BLOCKING_JOBS_END' || true; } \
        | sed 's/^[0-9]*\t//' \
        | sed '/^[[:space:]]*$/d')

    if [[ -n "${BLOCKING_LINES}" ]]; then
        DATA_AVAILABLE=true
        BLOCKING_COUNT=$(echo "${BLOCKING_LINES}" | wc -l)
        VERSIONS=$(echo "${BLOCKING_LINES}" | awk -F'|' '{print $5}' | sort -uV | paste -sd ', ')
        TOPOLOGIES=$(echo "${BLOCKING_LINES}" | awk -F'|' '{print $4}' | sort -u | paste -sd ', ')
    fi
else
    echo "Warning: ${LOG_FILE} not found."
fi

# ---------------------------------------------------------------------------
# Compose the Slack message
# ---------------------------------------------------------------------------
if [[ "${DATA_AVAILABLE}" != "true" ]]; then
    ICON=":warning:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — Blocking jobs data unavailable. Please investigate the artifacts."
elif [[ "${BLOCKING_COUNT}" -eq 0 ]]; then
    ICON=":large_green_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — No blocking jobs found."
else
    ICON=":red_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — *${BLOCKING_COUNT}* blocking job(s) found."
    MESSAGE+="\n• *Versions:* ${VERSIONS}"
    MESSAGE+="\n• *Topologies:* ${TOPOLOGIES}"
fi

MESSAGE+="\n<${DASHBOARD_URL}|View Dashboard> | <${JOB_URL}|Prow Logs> | @edge-enablement-payload-manager"

# ---------------------------------------------------------------------------
# Send to Slack
# ---------------------------------------------------------------------------
PAYLOAD=$(jq -nc --arg text "${MESSAGE}" '{"text": $text}')

curl -sf -X POST -H 'Content-type: application/json' \
    --data "${PAYLOAD}" \
    "${WEBHOOK_URL}"

echo "Slack notification sent (${BLOCKING_COUNT} blocking jobs found)."
