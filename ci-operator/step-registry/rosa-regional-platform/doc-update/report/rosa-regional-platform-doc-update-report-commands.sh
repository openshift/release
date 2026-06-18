#!/bin/bash
set -euo pipefail

echo "=== Rosa Regional Platform Documentation Update Report ==="

# HTML escape function to prevent script/markup injection
html_escape() {
  local input="$1"
  echo "$input" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&#39;/g'
}

OUTPUT_FILE="${SHARED_DIR:-/tmp}/claude-output.json"
REPORT_FILE="${ARTIFACT_DIR:-/tmp/artifacts}/doc-update-report.html"

# Ensure artifact directory exists
mkdir -p "$(dirname "${REPORT_FILE}")"

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "No output file found at ${OUTPUT_FILE}, creating minimal report"
  cat > "${REPORT_FILE}" <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>Documentation Update Report</title>
  <style>
    body { font-family: sans-serif; margin: 2em; }
    .error { color: red; }
  </style>
</head>
<body>
  <h1>Documentation Update Report</h1>
  <p><strong>Date:</strong> $(date)</p>
  <p class="error">No output file generated - job may have failed or exited early</p>
</body>
</html>
EOF
  echo "Minimal report generated: ${REPORT_FILE}"
  exit 0
fi

# Parse JSON results
UPDATES_NEEDED=$(jq -r '.updates_needed // false' "${OUTPUT_FILE}")
ANALYZED_PRS=$(jq -r '.analyzed_prs // 0' "${OUTPUT_FILE}")
STALE_DOCS=$(jq -r '.stale_docs // {}' "${OUTPUT_FILE}")
REPOS_UPDATED=$(jq -r '.repositories_updated // [] | join(", ")' "${OUTPUT_FILE}")
PRS_CREATED=$(jq -r '.prs_created // []' "${OUTPUT_FILE}")
PRS_COUNT=$(echo "${PRS_CREATED}" | jq 'length' 2>/dev/null || echo 0)
ERRORS=$(jq -r '.errors // []' "${OUTPUT_FILE}")
REASON=$(jq -r '.reason // ""' "${OUTPUT_FILE}")

# Generate HTML report
cat > "${REPORT_FILE}" <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>Documentation Update Report</title>
  <style>
    body { font-family: sans-serif; margin: 2em; }
    .success { color: green; }
    .info { color: blue; }
    .error { color: red; }
    .warning { color: orange; }
    pre { background: #f5f5f5; padding: 1em; overflow-x: auto; border: 1px solid #ddd; }
    table { border-collapse: collapse; width: 100%; margin: 1em 0; }
    th, td { border: 1px solid #ddd; padding: 0.5em; text-align: left; }
    th { background: #f0f0f0; }
    .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1em; margin: 1em 0; }
    .stat-card { border: 1px solid #ddd; padding: 1em; background: #fafafa; }
    .stat-value { font-size: 2em; font-weight: bold; }
  </style>
</head>
<body>
  <h1>Documentation Update Report</h1>
  <p><strong>Date:</strong> $(date)</p>
  <p><strong>Job:</strong> ${JOB_NAME:-unknown}</p>

  <div class="stat-grid">
    <div class="stat-card">
      <div>PRs Analyzed</div>
      <div class="stat-value">${ANALYZED_PRS}</div>
    </div>
    <div class="stat-card">
      <div>Updates Needed</div>
      <div class="stat-value $([ "${UPDATES_NEEDED}" = "true" ] && echo "warning" || echo "success")">${UPDATES_NEEDED}</div>
    </div>
    <div class="stat-card">
      <div>PRs Created</div>
      <div class="stat-value info">${PRS_COUNT}</div>
    </div>
    <div class="stat-card">
      <div>Repos Updated</div>
      <div class="stat-value warning">$(echo "${REPOS_UPDATED}" | wc -w)</div>
    </div>
  </div>

  <h2>Summary</h2>
EOF

if [ "${UPDATES_NEEDED}" = "true" ]; then
  # Escape REPOS_UPDATED
  REPOS_UPDATED_ESCAPED=$(html_escape "${REPOS_UPDATED}")
  # Escape stale docs
  STALE_DOCS_ESCAPED=$(echo "${STALE_DOCS}" | jq -r 'to_entries[] | "\(.key):\n" + (.value | map("  - " + .) | join("\n"))' 2>/dev/null || echo "No stale docs list")
  STALE_DOCS_ESCAPED=$(html_escape "${STALE_DOCS_ESCAPED}")

  cat >> "${REPORT_FILE}" <<EOF
  <p class="warning"><strong>Documentation updates were needed and processed.</strong></p>

  <h3>Repositories Updated</h3>
  <p>${REPOS_UPDATED_ESCAPED}</p>

  <h3>Stale Documentation Files by Repository</h3>
  <pre>${STALE_DOCS_ESCAPED}</pre>

  <h3>Pull Requests Created</h3>
EOF
  if [ "${PRS_COUNT}" -gt 0 ]; then
    cat >> "${REPORT_FILE}" <<EOF
  <table>
    <tr>
      <th>Repository</th>
      <th>PR Number</th>
      <th>Title</th>
      <th>URL</th>
    </tr>
EOF
    # Escape PR fields before inserting into HTML
    echo "${PRS_CREATED}" | jq -r '.[]' | while IFS= read -r pr_json; do
      REPO=$(echo "$pr_json" | jq -r '.repo')
      NUMBER=$(echo "$pr_json" | jq -r '.number')
      TITLE=$(echo "$pr_json" | jq -r '.title')
      URL=$(echo "$pr_json" | jq -r '.url')

      REPO_ESCAPED=$(html_escape "$REPO")
      TITLE_ESCAPED=$(html_escape "$TITLE")
      URL_ESCAPED=$(html_escape "$URL")

      cat >> "${REPORT_FILE}" <<PRROW
    <tr><td>${REPO_ESCAPED}</td><td>#${NUMBER}</td><td>${TITLE_ESCAPED}</td><td><a href="${URL_ESCAPED}">Link</a></td></tr>
PRROW
    done
    cat >> "${REPORT_FILE}" <<EOF
  </table>
EOF
  else
    cat >> "${REPORT_FILE}" <<EOF
  <p class="error">PR creation may have failed - check errors below</p>
EOF
  fi
else
  cat >> "${REPORT_FILE}" <<EOF
  <p class="success"><strong>No documentation updates needed.</strong></p>
EOF
  if [ -n "${REASON}" ] && [ "${REASON}" != "null" ]; then
    REASON_ESCAPED=$(html_escape "${REASON}")
    cat >> "${REPORT_FILE}" <<EOF
  <p><em>Reason:</em> ${REASON_ESCAPED}</p>
EOF
  fi
fi

# Add errors section if any
ERROR_COUNT=$(echo "${ERRORS}" | jq 'length' 2>/dev/null || echo 0)
if [ "${ERROR_COUNT}" -gt 0 ]; then
  cat >> "${REPORT_FILE}" <<EOF

  <h3 class="error">Errors Encountered (${ERROR_COUNT})</h3>
  <ul>
EOF
  echo "${ERRORS}" | jq -r '.[]' | while read -r error; do
    ERROR_ESCAPED=$(html_escape "$error")
    cat >> "${REPORT_FILE}" <<EOF
    <li class="error">${ERROR_ESCAPED}</li>
EOF
  done
  cat >> "${REPORT_FILE}" <<EOF
  </ul>
EOF
fi

# Add raw JSON output (escaped)
RAW_JSON=$(jq '.' "${OUTPUT_FILE}" 2>/dev/null || cat "${OUTPUT_FILE}")
RAW_JSON_ESCAPED=$(html_escape "$RAW_JSON")

cat >> "${REPORT_FILE}" <<EOF

  <h2>Raw Results</h2>
  <pre>${RAW_JSON_ESCAPED}</pre>
</body>
</html>
EOF

echo "Report generated: ${REPORT_FILE}"
cat "${REPORT_FILE}"
