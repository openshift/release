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
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>🔮 Continue This Claude Session Locally ✨</title>
<style>
  :root {
    --bg: #0f172a;
    --surface: #1e293b;
    --surface-hover: #334155;
    --border: #334155;
    --accent: #8b5cf6;
    --accent-glow: rgba(139, 92, 246, 0.25);
    --accent-light: #a78bfa;
    --text: #f1f5f9;
    --text-muted: #94a3b8;
    --success: #34d399;
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    padding: 3rem 2rem;
  }

  .container { max-width: 960px; width: 100%; margin: 0 auto; }

  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 2.5rem;
    box-shadow: 0 0 40px rgba(0, 0, 0, 0.3), 0 0 80px var(--accent-glow);
  }

  .title {
    font-size: 1.75rem;
    font-weight: 700;
    text-align: center;
    margin-bottom: 0.5rem;
    background: linear-gradient(135deg, var(--accent-light), var(--success));
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
  }

  .subtitle {
    text-align: center;
    color: var(--text-muted);
    font-size: 0.95rem;
    margin-bottom: 2rem;
  }

  .command-box {
    position: relative;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 1.25rem 3.5rem 1.25rem 1.25rem;
    font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 0.9rem;
    color: var(--accent-light);
    word-break: break-all;
    line-height: 1.6;
    transition: border-color 0.2s;
  }

  .command-box:hover { border-color: var(--accent); }

  .copy-btn {
    position: absolute;
    top: 0.75rem;
    right: 0.75rem;
    background: var(--surface-hover);
    border: 1px solid var(--border);
    border-radius: 8px;
    color: var(--text-muted);
    cursor: pointer;
    padding: 0.4rem 0.5rem;
    font-size: 1rem;
    line-height: 1;
    transition: all 0.2s;
    display: flex;
    align-items: center;
    gap: 0.25rem;
  }

  .copy-btn:hover {
    background: var(--accent);
    color: white;
    border-color: var(--accent);
  }

  .copy-btn.copied {
    background: var(--success);
    border-color: var(--success);
    color: white;
  }

  .instructions {
    margin-top: 2rem;
    padding: 1.25rem;
    background: rgba(139, 92, 246, 0.08);
    border: 1px solid rgba(139, 92, 246, 0.2);
    border-radius: 10px;
  }

  .instructions h3 {
    font-size: 0.85rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--accent-light);
    margin-bottom: 0.75rem;
  }

  .instructions ol {
    list-style: none;
    counter-reset: steps;
  }

  .instructions li {
    counter-increment: steps;
    color: var(--text-muted);
    font-size: 0.9rem;
    padding: 0.3rem 0;
    padding-left: 1.75rem;
    position: relative;
  }

  .instructions li::before {
    content: counter(steps);
    position: absolute;
    left: 0;
    color: var(--accent-light);
    font-weight: 600;
    font-size: 0.8rem;
    background: rgba(139, 92, 246, 0.15);
    width: 1.25rem;
    height: 1.25rem;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    top: 0.4rem;
  }

  .instructions a {
    color: var(--accent-light);
    text-decoration: none;
    border-bottom: 1px dotted var(--accent-light);
  }

  .instructions a:hover { border-bottom-style: solid; }

  .instructions code {
    background: var(--bg);
    padding: 0.15rem 0.4rem;
    border-radius: 4px;
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.85rem;
    color: var(--accent-light);
  }

  .footer {
    margin-top: 2rem;
    text-align: center;
    padding-top: 1.5rem;
    border-top: 1px solid var(--border);
  }

  .footer p {
    color: var(--text-muted);
    font-size: 0.85rem;
    margin-bottom: 0.75rem;
  }

  .footer a {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    color: var(--accent-light);
    text-decoration: none;
    font-weight: 500;
    font-size: 0.9rem;
    padding: 0.5rem 1rem;
    border: 1px solid rgba(139, 92, 246, 0.3);
    border-radius: 8px;
    transition: all 0.2s;
  }

  .footer a:hover {
    background: rgba(139, 92, 246, 0.1);
    border-color: var(--accent);
  }

  .footer a svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
  }
</style>
</head>
<body>
<div class="container">
  <div class="card">
    <h1 class="title">🔮 Continue This Claude Session Locally ✨</h1>
    <p class="subtitle">Pick up right where the CI agent left off</p>

    <div class="command-box">
      <span id="cmd">/ci:continue-session ${PROW_URL}</span>
      <button class="copy-btn" onclick="copyCommand(this)" title="Copy to clipboard">📋</button>
    </div>

    <div class="instructions">
      <h3>How to use</h3>
      <ol>
        <li>Install the <a href="https://github.com/openshift-eng/ai-helpers" target="_blank" rel="noopener"><strong>ai-helpers</strong></a> marketplace</li>
        <li>Open Claude Code in your terminal</li>
        <li>Paste the command above and press Enter</li>
        <li>Claude will download the session and help you resume the conversation</li>
      </ol>
    </div>

    <div class="footer">
      <p>Requires the ai-helpers marketplace for Claude Code</p>
      <a href="https://github.com/openshift-eng/ai-helpers" target="_blank" rel="noopener">
        <svg viewBox="0 0 16 16"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
        openshift-eng/ai-helpers
      </a>
    </div>
  </div>
</div>

<script>
function copyCommand(btn) {
  var text = document.getElementById('cmd').textContent;
  navigator.clipboard.writeText(text).then(function() {
    btn.textContent = '✅';
    btn.classList.add('copied');
    setTimeout(function() {
      btn.textContent = '📋';
      btn.classList.remove('copied');
    }, 2000);
  });
}
</script>
</body>
</html>
HTMLEOF

echo "Continue-session page written to ${ARTIFACT_DIR}/continue-session-summary.html"
