#!/bin/bash
#
# Post adversary scan results to Slack.
#
# Reads the findings summary from SHARED_DIR (written by the scan step)
# and sends a traffic-light notification via Slack incoming webhook.
#
# Required env:
#   SLACK_WEBHOOK_PATH  -- path to file containing the webhook URL
#
# Provided by ci-operator:
#   SHARED_DIR          -- shared volume with the scan step
#   JOB_NAME            -- Prow job name
#   BUILD_ID            -- Prow build ID
#   REPO_OWNER          -- GitHub org (presubmits)
#   REPO_NAME           -- GitHub repo (presubmits)

set -o nounset
set -o errexit
set -o pipefail

echo "=== Adversary Scan Notification ==="

# -----------------------------------------------------------------------
# Guard: skip if scan did not complete
# -----------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/adversary-scan-completed" ]]; then
    echo "Scan step did not complete — skipping notification."
    exit 0
fi

# -----------------------------------------------------------------------
# Guard: skip if no webhook configured
# -----------------------------------------------------------------------
if [[ ! -f "${SLACK_WEBHOOK_PATH}" ]]; then
    echo "No Slack webhook found at ${SLACK_WEBHOOK_PATH} — skipping notification."
    exit 0
fi

# -----------------------------------------------------------------------
# Read findings summary
# -----------------------------------------------------------------------
FINDINGS_FILE="${SHARED_DIR}/adversary-findings-summary.txt"

if [[ ! -f "${FINDINGS_FILE}" ]]; then
    echo "No findings summary found — skipping notification."
    exit 0
fi

# Source the key=value pairs
CRITICAL=0
HIGH=0
MEDIUM=0
LOW=0
SCAN_MODE="unknown"
SCAN_DURATION=0

while IFS='=' read -r key value; do
    case "${key}" in
        CRITICAL) CRITICAL="${value}" ;;
        HIGH) HIGH="${value}" ;;
        MEDIUM) MEDIUM="${value}" ;;
        LOW) LOW="${value}" ;;
        SCAN_MODE) SCAN_MODE="${value}" ;;
        SCAN_DURATION) SCAN_DURATION="${value}" ;;
    esac
done < "${FINDINGS_FILE}"

TOTAL=$(( CRITICAL + HIGH + MEDIUM + LOW ))

echo "Findings: ${CRITICAL} critical, ${HIGH} high, ${MEDIUM} medium, ${LOW} low"

# -----------------------------------------------------------------------
# Build Prow job URL and report link
# -----------------------------------------------------------------------
JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
GCS_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
REPORT_URL="${GCS_BASE}/logs/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME##*-}/security-adversary-scan/artifacts/"

REPO="${REPO_OWNER:-unknown}/${REPO_NAME:-unknown}"
NL=$'\n'

# -----------------------------------------------------------------------
# Traffic-light logic
# -----------------------------------------------------------------------
if [[ $(( CRITICAL + HIGH )) -gt 0 ]]; then
    ICON=":red_circle:"
    MESSAGE="${ICON} *Adversary Security Scan* — ${REPO} (${SCAN_MODE})"
    MESSAGE+="${NL}*${CRITICAL}* critical, *${HIGH}* high, *${MEDIUM}* medium, *${LOW}* low"
elif [[ $(( MEDIUM + LOW )) -gt 0 ]]; then
    ICON=":large_yellow_circle:"
    MESSAGE="${ICON} *Adversary Security Scan* — ${REPO} (${SCAN_MODE})"
    MESSAGE+="${NL}*${MEDIUM}* medium, *${LOW}* low"
else
    ICON=":large_green_circle:"
    MESSAGE="${ICON} *Adversary Security Scan* — ${REPO} (${SCAN_MODE}) — No findings."
fi

# Format duration
MINS=$(( SCAN_DURATION / 60 ))
SECS=$(( SCAN_DURATION % 60 ))
if [[ ${MINS} -gt 0 ]]; then
    DURATION_STR="${MINS}m ${SECS}s"
else
    DURATION_STR="${SECS}s"
fi

MESSAGE+="${NL}Duration: ${DURATION_STR} | <${REPORT_URL}|View Report> | <${JOB_URL}|Prow Logs>"

# -----------------------------------------------------------------------
# Send to Slack
# -----------------------------------------------------------------------
echo "--- Slack message preview ---"
echo "${MESSAGE}"
echo "-----------------------------"

set +x
WEBHOOK_URL=$(cat "${SLACK_WEBHOOK_PATH}")
PAYLOAD=$(jq -nc --arg text "${MESSAGE}" '{"text": $text}')

curl -sf -X POST -H 'Content-type: application/json' \
    --connect-timeout 10 --max-time 20 \
    --data "${PAYLOAD}" \
    "${WEBHOOK_URL}"

echo "Slack notification sent."
