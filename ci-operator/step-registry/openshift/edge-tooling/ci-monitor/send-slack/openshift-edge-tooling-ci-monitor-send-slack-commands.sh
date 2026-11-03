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
JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results-public/logs/${JOB_NAME}/${BUILD_ID}"
GCS_BASE="https://gcs.ci.openshift.org/gcs/test-platform-results-public"
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
# Read Sippy counts before choosing the status header.
# The payload monitor counts every distinct Sippy job/release with at least
# three runs and relative change < -50%, independently of AI target selection.
# A null count means Sippy data was unavailable for that release.
# ---------------------------------------------------------------------------
SIPPY_COUNT=0
SIPPY_AVAILABLE=0
SIPPY_UNAVAILABLE=""
SIPPY_SUMMARY="${SHARED_DIR}/sippy-summary.json"
if [[ -r "${SIPPY_SUMMARY}" ]] && jq -e '
    type == "object" and length > 0 and
    all(.[]; . == null or (type == "number" and . >= 0 and . == floor))
    ' "${SIPPY_SUMMARY}" >/dev/null 2>&1; then
    SIPPY_COUNT=$(jq '[.[] | select(. != null)] | add // 0' "${SIPPY_SUMMARY}")
    SIPPY_AVAILABLE=$(jq '[.[] | select(. != null)] | length' "${SIPPY_SUMMARY}")
    SIPPY_UNAVAILABLE=$(jq -r 'to_entries | map(select(.value == null) | .key) | join(", ")' "${SIPPY_SUMMARY}")
fi

# ---------------------------------------------------------------------------
# Compose the Slack message
# ---------------------------------------------------------------------------
NL=$'\n'

if [[ "${DATA_AVAILABLE}" != "true" ]]; then
    ICON=":warning:"
    MESSAGE="${ICON} *Edge OCP CI Monitor* — Data unavailable. Please investigate the artifacts."
elif [[ "${BLOCKING_COUNT}" -eq 0 ]] && [[ "${INFORMING_COUNT}" -eq 0 ]]; then
    if [[ "${SIPPY_AVAILABLE}" -gt 0 ]] && [[ "${SIPPY_COUNT}" -eq 0 ]] && [[ -z "${SIPPY_UNAVAILABLE}" ]]; then
        ICON=":large_green_circle:"
        MESSAGE="${ICON} *Edge OCP CI Monitor* — No failing jobs found."
    else
        ICON=":warning:"
        MESSAGE="${ICON} *Edge OCP CI Monitor* — No failing payload jobs found."
    fi
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

if [[ "${SIPPY_AVAILABLE}" -eq 0 ]]; then
    MESSAGE+="${NL}:warning: Sippy test job drop counts unavailable."
elif [[ -n "${SIPPY_UNAVAILABLE}" ]]; then
    MESSAGE+="${NL}:chart_with_downwards_trend: At least *${SIPPY_COUNT}* Sippy job/release pair(s) have a pass-rate drop of more than 50%."
else
    MESSAGE+="${NL}:chart_with_downwards_trend: *${SIPPY_COUNT}* Sippy job/release pair(s) have a pass-rate drop of more than 50%."
fi
if [[ -n "${SIPPY_UNAVAILABLE}" ]]; then
    MESSAGE+="${NL}Sippy data unavailable for: ${SIPPY_UNAVAILABLE}."
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
    WEBHOOK_URL=$(cat /var/run/slack-webhook/team-ocp-edge-notifications)
    PAYLOAD=$(jq -nc --arg text "${MESSAGE}" '{"text": $text}')

    curl -sf -X POST -H 'Content-type: application/json' \
        --data "${PAYLOAD}" \
        "${WEBHOOK_URL}"

    echo "Slack notification sent (${BLOCKING_COUNT} blocking, ${INFORMING_COUNT} informing)."
fi
