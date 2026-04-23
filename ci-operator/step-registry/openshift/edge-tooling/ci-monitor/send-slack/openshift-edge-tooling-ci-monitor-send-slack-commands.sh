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
# Read pre-extracted blocking jobs from SHARED_DIR
#
# The monitor step extracts pipe-separated entries into blocking-jobs.txt:
#   BLOCKING|<job_name>|<prow_url>|<topology>|<version>|<payload>
# ---------------------------------------------------------------------------
JOBS_FILE="${SHARED_DIR}/blocking-jobs.txt"

BLOCKING_COUNT=0
VERSIONS=""
TOPOLOGIES=""
DATA_AVAILABLE=false

if [[ -f "${JOBS_FILE}" ]]; then
    DATA_AVAILABLE=true
    BLOCKING_LINES=$(<"${JOBS_FILE}")

    if [[ -n "${BLOCKING_LINES}" ]]; then
        BLOCKING_COUNT=$(echo "${BLOCKING_LINES}" | wc -l)
        VERSIONS=$(echo "${BLOCKING_LINES}" | awk -F'|' '{print $5}' | sort -uV | tr '\n' ',' | sed 's/,/, /g; s/, $//')
        TOPOLOGIES=$(echo "${BLOCKING_LINES}" | awk -F'|' '{print $4}' | sort -u | tr '\n' ',' | sed 's/,/, /g; s/, $//')
    fi
else
    echo "Warning: ${JOBS_FILE} not found."
fi

# ---------------------------------------------------------------------------
# Compose the Slack message
# ---------------------------------------------------------------------------
NL=$'\n'

if [[ "${DATA_AVAILABLE}" != "true" ]]; then
    ICON=":warning:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — Blocking jobs data unavailable. Please investigate the artifacts."
elif [[ "${BLOCKING_COUNT}" -eq 0 ]]; then
    ICON=":large_green_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — No blocking jobs found."
else
    ICON=":red_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — *${BLOCKING_COUNT}* blocking job(s) found."
    MESSAGE+="${NL}• *Versions:* ${VERSIONS}"
    MESSAGE+="${NL}• *Topologies:* ${TOPOLOGIES}"
fi

MESSAGE+="${NL}<${DASHBOARD_URL}|View Dashboard> | <${JOB_URL}|Prow Logs> | @edge-enablement-payload-manager"

# ---------------------------------------------------------------------------
# Send to Slack
# ---------------------------------------------------------------------------
PAYLOAD=$(jq -nc --arg text "${MESSAGE}" '{"text": $text}')

curl -sf -X POST -H 'Content-type: application/json' \
    --data "${PAYLOAD}" \
    "${WEBHOOK_URL}"

echo "Slack notification sent (${BLOCKING_COUNT} blocking jobs found)."
