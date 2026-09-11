#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/claude-session-available" ]]; then
    echo "No Claude session archive found. Skipping."
    exit 0
fi

echo "Claude session archive detected. Generating continue-session page..."

# Build the Prow job URL
if [[ "${JOB_TYPE:-}" == "presubmit" ]]; then
    PROW_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    PROW_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
fi

cat > "${ARTIFACT_DIR}/continue-session-summary.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Continue This Claude Session Locally ✨</title>
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
<h1>Continue This Claude Session Locally ✨</h1>
<p class="subtitle">Pick up right where the CI agent left off. Click below to copy.</p>
<pre id="cmd" onclick="navigator.clipboard.writeText(this.textContent).then(()=>{this.style.borderColor='#4caf50';setTimeout(()=>this.style.borderColor='',1500)})">/ci:continue-session ${PROW_URL}</pre>
<ol>
  <li>Install the <a href="https://github.com/openshift-eng/ai-helpers" target="_blank"><strong>ai-helpers</strong></a> marketplace</li>
  <li>Open Claude Code in your terminal</li>
  <li>Paste the command above and press Enter</li>
  <li>Claude will download the session and help you resume the conversation</li>
</ol>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
</body>
</html>
HTMLEOF

echo "Continue-session page written to ${ARTIFACT_DIR}/continue-session-summary.html"
