#!/bin/bash
set -euo pipefail
set -x

if [ "${JOB_TYPE:-}" = "presubmit" ]; then
    GCSWEB_JOB_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    GCSWEB_JOB_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
fi

download_report() {
    local -r report_name="report-lvm-operator-ci-doctor.html"
    local -r report_url="${GCSWEB_JOB_URL}/artifacts/lvms-ci-doctor/openshift-edge-tooling-lvms-ci-doctor/artifacts/${report_name}"
    local -r output_file="${ARTIFACT_DIR}/0-${report_name%.html}-summary.html"

    echo "Downloading report from artifacts..."
    curl -sSfL --retry 3 --max-time 300 -o "${output_file}" "${report_url}"
    echo "Report downloaded successfully."
}

#
# Main
#
echo "Generating the report pages..."

if [[ -f "${SHARED_DIR}/claude-report-available" ]]; then
    download_report
else
    echo "No Claude report found. Skipping."
fi

#
# Send Slack notification to #team-ocp-edge-notifications
# (Prow reporter_config already sends to #lvms-release-coordination)
#
WEBHOOK_FILE="/var/run/slack-webhook/team-ocp-edge-notifications"
if [[ -f "${WEBHOOK_FILE}" ]] && [[ "${JOB_TYPE:-}" == "periodic" ]]; then
    REPORT_URL="${GCSWEB_JOB_URL}/artifacts/lvms-ci-doctor/openshift-edge-tooling-lvms-ci-doctor/artifacts/report-lvm-operator-ci-doctor.html"
    MESSAGE=":robot_face: *LVMS CI Doctor* report available.\n| <${REPORT_URL}|Report> | <https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}|Logs> |"
    PAYLOAD=$(jq -nc --arg text "${MESSAGE}" '{"text": $text}')
    set +x
    curl -sf --connect-timeout 10 --max-time 30 -X POST -H 'Content-type: application/json' \
        --data "${PAYLOAD}" \
        "$(cat "${WEBHOOK_FILE}")" \
        && echo "Slack notification sent to #team-ocp-edge-notifications." \
        || echo "Warning: Slack notification failed (non-fatal)."
    set -x
else
    echo "Skipping Slack notification (webhook not available or not a periodic job)."
fi
