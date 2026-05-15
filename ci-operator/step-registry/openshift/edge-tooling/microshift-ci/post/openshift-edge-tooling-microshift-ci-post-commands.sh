#!/bin/bash
set -euo pipefail
set -x

if [ "${JOB_TYPE:-}" = "presubmit" ]; then
    GCSWEB_JOB_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    GCSWEB_JOB_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
fi

download_report() {
    local -r report_name="microshift-ci-doctor-report.html"
    local -r report_url="${GCSWEB_JOB_URL}/artifacts/microshift-ci-doctor/openshift-edge-tooling-microshift-ci-doctor/artifacts/${report_name}"
    local -r output_file="${ARTIFACT_DIR}/0-${report_name%.html}-summary.html"

    echo "Downloading report from artifacts..."
    curl -sSfL --retry 3 --max-time 300 -o "${output_file}" "${report_url}"
    echo "Report downloaded successfully."
}

generate_continue_session_page() {
    local -r summary_name="${ARTIFACT_DIR}/1-continue-session-summary.html"
    cat > "${summary_name}" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Continue This MicroShift CI Session Locally</title>
<style>
  body { font-family: system-ui, sans-serif; background: #1a1a2e; color: #e0e0e0; max-width: 960px; margin: 0 auto; padding: 3rem 2rem; }
  h1 { text-align: center; }
  .subtitle { text-align: center; color: #888; margin-bottom: 2rem; }
  pre { background: #111; border: 1px solid #333; border-radius: 8px; padding: 1rem; color: #b39ddb; word-break: break-all; white-space: pre-wrap; cursor: pointer; position: relative; }
  pre:hover { border-color: #7c4dff; }
  ol { color: #aaa; margin: 2rem 0; padding-left: 1.5rem; }
  li { padding: 0.25rem 0; }
  a { color: #b39ddb; }
</style>
</head>
<body>
<h1>Continue This MicroShift CI Session Locally</h1>
<p class="subtitle">Pick up right where the MicroShift CI agent left off. Click below to copy.</p>
<pre id="cmd" onclick="navigator.clipboard.writeText(this.textContent).then(()=>{this.style.borderColor='#4caf50';setTimeout(()=>this.style.borderColor='',1500)})">/microshift-ci:continue-session ${PROW_JOB_URL}</pre>
<ol>
  <li>Install the <strong>microshift-ci</strong> plugin: <code>claude plugin add openshift-eng/edge-tooling/plugins/microshift-ci</code></li>
  <li>Open Claude Code in your terminal</li>
  <li>Paste the command above and press Enter</li>
  <li>Claude will download the CI artifacts to a local work directory so you can use <code>/microshift-ci:*</code> skills on them</li>
</ol>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
</body>
</html>
HTMLEOF
    echo "Continue-session page written to ${summary_name}"
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

if [[ -f "${SHARED_DIR}/claude-session-available" ]]; then
    generate_continue_session_page
else
    echo "No Claude session archive found. Skipping continue-session page."
fi
