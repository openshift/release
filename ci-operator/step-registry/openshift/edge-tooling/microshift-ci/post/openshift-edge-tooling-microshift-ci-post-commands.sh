#!/bin/bash
set -euo pipefail
set -x

if [ "${JOB_TYPE:-}" = "presubmit" ]; then
    PROW_JOB_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    PROW_JOB_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
fi

download_report() {
    local -r report_name="microshift-ci-doctor-report.html"
    local -r report_url="${PROW_JOB_URL}/artifacts/microshift-ci-doctor/openshift-edge-tooling-microshift-ci-doctor/artifacts/${report_name}"
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
