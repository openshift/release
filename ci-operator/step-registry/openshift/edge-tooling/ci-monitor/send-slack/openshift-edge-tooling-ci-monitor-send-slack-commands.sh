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
# Read pre-extracted job data from SHARED_DIR
#
# Each line is pipe-delimited with a type prefix:
#   BLOCKING|<job_name>|<prow_url>|<topology>|<version>|<payload>
#   INFORMING|<job_name>|<prow_url>|<topology>|<version>|<payload>
# ---------------------------------------------------------------------------
JOBS_FILE="${SHARED_DIR}/failing-jobs.txt"

BLOCKING_COUNT=0
INFORMING_COUNT=0
DATA_AVAILABLE=false

if [[ -f "${JOBS_FILE}" ]]; then
    DATA_AVAILABLE=true
    BLOCKING_LINES=$(grep '^BLOCKING|' "${JOBS_FILE}" || true)
    INFORMING_LINES=$(grep '^INFORMING|' "${JOBS_FILE}" || true)

    [[ -n "${BLOCKING_LINES}" ]] && BLOCKING_COUNT=$(echo "${BLOCKING_LINES}" | wc -l)
    [[ -n "${INFORMING_LINES}" ]] && INFORMING_COUNT=$(echo "${INFORMING_LINES}" | wc -l)
else
    echo "Warning: ${JOBS_FILE} not found."
fi

# ---------------------------------------------------------------------------
# Build per-version aggregated counts from pipe-delimited job data.
# Produces output like: 4.19 (1), 4.20 (0), 4.21 (2), 5.0 (1)
#
# $1 = lines to count (one type)
# $2 = all lines (both types) — used to build the full version list so
#      versions with zero failures for this type still appear
# ---------------------------------------------------------------------------
version_summary() {
    local job_lines="$1"
    local all_lines="$2"

    local versions
    versions=$(echo "${all_lines}" | awk -F'|' '{print $5}' | sort -uV)

    local result=""
    while IFS= read -r ver; do
        [[ -z "${ver}" ]] && continue
        local count=0
        if [[ -n "${job_lines}" ]]; then
            count=$(echo "${job_lines}" | awk -F'|' -v v="${ver}" '$5 == v' | wc -l)
        fi
        result+="${result:+, }${ver} (${count})"
    done <<< "${versions}"
    echo "${result}"
}

# ---------------------------------------------------------------------------
# Compose the Slack message
# ---------------------------------------------------------------------------
NL=$'\n'
ALL_LINES="${BLOCKING_LINES}${BLOCKING_LINES:+$'\n'}${INFORMING_LINES}"

if [[ "${DATA_AVAILABLE}" != "true" ]]; then
    ICON=":warning:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — Data unavailable. Please investigate the artifacts."
elif [[ "${BLOCKING_COUNT}" -eq 0 ]] && [[ "${INFORMING_COUNT}" -eq 0 ]]; then
    ICON=":large_green_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — No failing jobs found."
elif [[ "${BLOCKING_COUNT}" -eq 0 ]]; then
    ICON=":large_yellow_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — No failing blocking jobs."
    INFORMING_SUMMARY=$(version_summary "${INFORMING_LINES}" "${ALL_LINES}")
    MESSAGE+="${NL}:warning: *${INFORMING_COUNT}* failing informing job(s): ${INFORMING_SUMMARY}"
else
    ICON=":red_circle:"
    BLOCKING_SUMMARY=$(version_summary "${BLOCKING_LINES}" "${ALL_LINES}")
    MESSAGE="${ICON} *Edge OCP CI Monitor* — *${BLOCKING_COUNT}* failing blocking job(s): ${BLOCKING_SUMMARY}"
    if [[ "${INFORMING_COUNT}" -gt 0 ]]; then
        MESSAGE+="${NL}:warning: *${INFORMING_COUNT}* failing informing job(s)"
    fi
fi

MESSAGE+="${NL}<${DASHBOARD_URL}|View Dashboard> | <${JOB_URL}|Prow Logs> | @edge-enablement-payload-manager"

# ---------------------------------------------------------------------------
# Send to Slack
# ---------------------------------------------------------------------------
PAYLOAD=$(jq -nc --arg text "${MESSAGE}" '{"text": $text}')

curl -sf -X POST -H 'Content-type: application/json' \
    --data "${PAYLOAD}" \
    "${WEBHOOK_URL}"

echo "Slack notification sent (${BLOCKING_COUNT} blocking, ${INFORMING_COUNT} informing)."
