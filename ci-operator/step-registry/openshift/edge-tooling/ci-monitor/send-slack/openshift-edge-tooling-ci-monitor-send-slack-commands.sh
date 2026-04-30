#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Guards — skip sending in certain conditions
# ---------------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/monitor-completed" ]]; then
    echo "Monitor step did not complete — skipping Slack notification."
    exit 0
fi

DRY_RUN=false
if [[ "${JOB_TYPE:-}" != "periodic" ]]; then
    echo "Non-periodic job (${JOB_TYPE:-unknown}) — will dry-run only."
    DRY_RUN=true
fi

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
BLOCKING_LINES=""
INFORMING_LINES=""
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
# $1 = lines to count (one type) — versions are derived from these lines
#      so only versions with actual failures for this type appear
# ---------------------------------------------------------------------------
version_summary() {
    local job_lines="$1"

    [[ -z "${job_lines}" ]] && return

    local versions
    versions=$(echo "${job_lines}" | awk -F'|' '{print $5}' | sort -uV)

    local result=""
    while IFS= read -r ver; do
        [[ -z "${ver}" ]] && continue
        local count
        count=$(echo "${job_lines}" | awk -F'|' -v v="${ver}" '$5 == v' | wc -l)
        result+="${result:+, }${ver} (${count})"
    done <<< "${versions}"
    echo "${result}"
}

# ---------------------------------------------------------------------------
# Compose the Slack message
# ---------------------------------------------------------------------------
NL=$'\n'

if [[ "${DATA_AVAILABLE}" != "true" ]]; then
    ICON=":warning:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — Data unavailable. Please investigate the artifacts."
elif [[ "${BLOCKING_COUNT}" -eq 0 ]] && [[ "${INFORMING_COUNT}" -eq 0 ]]; then
    ICON=":large_green_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — No failing jobs found."
elif [[ "${BLOCKING_COUNT}" -eq 0 ]]; then
    ICON=":large_yellow_circle:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — No failing blocking jobs."
    INFORMING_SUMMARY=$(version_summary "${INFORMING_LINES}")
    INFORMING_TOPOS=$(echo "${INFORMING_LINES}" | awk -F'|' '{print $4}' | sort -u | tr '\n' ',' | sed 's/,/, /g; s/, $//')
    MESSAGE+="${NL}:warning: *${INFORMING_COUNT}* failing informing job(s)"
    MESSAGE+="${NL}• *Versions:* ${INFORMING_SUMMARY}"
    MESSAGE+="${NL}• *Topologies:* ${INFORMING_TOPOS}"
else
    ICON=":red_circle:"
    BLOCKING_SUMMARY=$(version_summary "${BLOCKING_LINES}")
    BLOCKING_TOPOS=$(echo "${BLOCKING_LINES}" | awk -F'|' '{print $4}' | sort -u | tr '\n' ',' | sed 's/,/, /g; s/, $//')
    MESSAGE="${ICON} *Edge OCP CI Monitor* — *${BLOCKING_COUNT}* failing blocking job(s)."
    MESSAGE+="${NL}• *Versions:* ${BLOCKING_SUMMARY}"
    MESSAGE+="${NL}• *Topologies:* ${BLOCKING_TOPOS}"
    if [[ "${INFORMING_COUNT}" -gt 0 ]]; then
        MESSAGE+="${NL}:warning: *${INFORMING_COUNT}* failing informing job(s)"
    fi
fi

MESSAGE+="${NL}<${DASHBOARD_URL}|View Dashboard> | <${JOB_URL}|Prow Logs> | @edge-enablement-payload-manager"

# ---------------------------------------------------------------------------
# Send to Slack (or dry-run on PRs)
# ---------------------------------------------------------------------------
echo "--- Slack message preview ---"
echo "${MESSAGE}"
echo "-----------------------------"

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Dry-run complete — message NOT sent since this is not a periodic job."
else
    WEBHOOK_URL=$(cat /var/run/slack-webhook/ocp-ci-monitor)
    PAYLOAD=$(jq -nc --arg text "${MESSAGE}" '{"text": $text}')

    curl -sf -X POST -H 'Content-type: application/json' \
        --data "${PAYLOAD}" \
        "${WEBHOOK_URL}"

    echo "Slack notification sent (${BLOCKING_COUNT} blocking, ${INFORMING_COUNT} informing)."
fi
