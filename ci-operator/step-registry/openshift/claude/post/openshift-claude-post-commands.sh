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

CONTINUE_CMD="/ci:continue-session ${PROW_URL}"
# The claude-cli:// link needs to cd into a temp dir first so Claude Code
# doesn't open in $HOME with all its files in context.
OPEN_CMD="cd \$(mktemp -d) && ${CONTINUE_CMD}"
ENCODED_CMD=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "${OPEN_CMD}")
CLAUDE_CLI_URL="claude-cli://open?q=${ENCODED_CMD}"

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
  .open-btn { display: block; width: fit-content; margin: 1.5rem auto; padding: 0.75rem 2rem; background: #7c4dff; color: #fff; text-decoration: none; border-radius: 8px; font-size: 1.1rem; font-weight: 600; transition: background 0.2s; }
  .open-btn:hover { background: #651fff; }
  .or-divider { text-align: center; color: #666; margin: 1.5rem 0; font-size: 0.9rem; }
  pre { background: #111; border: 1px solid #333; border-radius: 8px; padding: 1rem; color: #b39ddb; word-break: break-all; white-space: pre-wrap; cursor: pointer; position: relative; }
  pre:hover { border-color: #7c4dff; }
  .copied-msg { text-align: center; color: #4caf50; font-size: 0.85rem; height: 1.2em; margin-top: 0.5rem; }
  ol { color: #aaa; margin: 2rem 0; padding-left: 1.5rem; }
  li { padding: 0.25rem 0; }
  a { color: #b39ddb; }
</style>
</head>
<body>
<h1>Continue This Claude Session Locally ✨</h1>
<p class="subtitle">Pick up right where the CI agent left off.</p>
<a class="open-btn" href="${CLAUDE_CLI_URL}">Open in Claude Code</a>
<p class="or-divider">— or copy the command manually —</p>
<pre id="cmd" onclick="navigator.clipboard.writeText(this.textContent).then(()=>{document.getElementById('copied').textContent='Copied!';this.style.borderColor='#4caf50';setTimeout(()=>{this.style.borderColor='';document.getElementById('copied').textContent=''},1500)})">${CONTINUE_CMD}</pre>
<p class="copied-msg" id="copied"></p>
<ol>
  <li>Install the <a href="https://github.com/openshift-eng/ai-helpers" target="_blank"><strong>ai-helpers</strong></a> marketplace</li>
  <li>Click <strong>Open in Claude Code</strong> above, or copy the command and paste it into Claude Code</li>
  <li>Claude will download the session and help you resume the conversation</li>
</ol>
</body>
</html>
HTMLEOF

echo "Continue-session page written to ${ARTIFACT_DIR}/continue-session-summary.html"
