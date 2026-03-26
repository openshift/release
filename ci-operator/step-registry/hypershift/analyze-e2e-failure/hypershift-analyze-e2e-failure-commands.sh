#!/bin/bash
set -euo pipefail

echo "=== HyperShift E2E Failure Analyzer ==="

# ---------------------------------------------------------------------------
# 1. Construct GCS base path and detect test failures
# ---------------------------------------------------------------------------
JOB_NAME="${JOB_NAME:-unknown}"
BUILD_ID="${BUILD_ID:-unknown}"
JOB_TYPE="${JOB_TYPE:-}"
PULL_NUMBER="${PULL_NUMBER:-}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"

# Build GCS bucket path from CI env vars
if [[ "$JOB_TYPE" == "presubmit" ]] && [[ -n "$PULL_NUMBER" ]]; then
  GCS_BUCKET_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  GCS_BUCKET_PATH="logs/${JOB_NAME}/${BUILD_ID}"
fi

GCSWEB_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
PROW_JOB_URL="${GCSWEB_BASE}/${GCS_BUCKET_PATH}"

# Extract the test target name (e.g., e2e-aws from pull-ci-openshift-hypershift-main-e2e-aws)
JOB_NAME_SHORT="${JOB_NAME##*-main-}"

# Check for test failures by fetching finished.json from test step artifacts in GCS.
# Each CI step uploads its own finished.json with {"passed":true/false} upon completion.
# By the time post-steps run, test step artifacts are already in GCS.
echo "Checking for test failures in GCS..."

FAILURE_DETECTED=false
ARTIFACTS_BASE="${GCSWEB_BASE}/${GCS_BUCKET_PATH}/artifacts/${JOB_NAME_SHORT}"

# List step directories and check each finished.json for failures
STEP_LIST_URL="${ARTIFACTS_BASE}/"
STEP_DIRS=$(curl -sL "$STEP_LIST_URL" | grep -oP 'href="[^"]*/"' | grep -oP '/[^/"]+/$' | tr -d '/' | grep -v '^$' || true)

if [[ -z "$STEP_DIRS" ]]; then
  echo "Warning: Could not list step directories from GCS — checking build-log directly"
  # Fallback: try to fetch the build-log from the most common test step names
  for STEP_NAME in hypershift-aws-run-e2e-external hypershift-azure-run-e2e hypershift-aws-run-e2e; do
    FINISHED_URL="${ARTIFACTS_BASE}/${STEP_NAME}/finished.json"
    FINISHED_JSON=$(curl -sL "$FINISHED_URL" 2>/dev/null || true)
    if echo "$FINISHED_JSON" | jq -e '.passed == false' &>/dev/null; then
      echo "Detected test failure in ${STEP_NAME}/finished.json"
      FAILURE_DETECTED=true
      break
    fi
  done
else
  for STEP_DIR in $STEP_DIRS; do
    # Skip our own step and gather/cleanup steps
    [[ "$STEP_DIR" == "hypershift-analyze-e2e-failure" ]] && continue
    FINISHED_URL="${ARTIFACTS_BASE}/${STEP_DIR}/finished.json"
    FINISHED_JSON=$(curl -sL "$FINISHED_URL" 2>/dev/null || true)
    if echo "$FINISHED_JSON" | jq -e '.passed == false' &>/dev/null; then
      echo "Detected test failure in ${STEP_DIR}/finished.json"
      FAILURE_DETECTED=true
      break
    fi
  done
fi

if [[ "$FAILURE_DETECTED" == "false" ]]; then
  echo "No test failures detected — skipping analysis."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Verify Claude Code CLI
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping analysis"
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"

# ---------------------------------------------------------------------------
# 3. Clone ai-helpers and set up skill
# ---------------------------------------------------------------------------
echo "Cloning ai-helpers repository..."
git clone --depth 1 https://github.com/openshift-eng/ai-helpers /tmp/ai-helpers

SKILL_FILE="/tmp/ai-helpers/plugins/ci/skills/prow-job-analyze-test-failure/SKILL.md"

if [[ ! -f "$SKILL_FILE" ]]; then
  echo "ERROR: Skill file not found at $SKILL_FILE — skipping analysis"
  exit 0
fi

# Load both command and skill content as system prompt (skill has the implementation details)
SKILL_CONTENT=$(cat "$SKILL_FILE")

# Also load dependent skills that are referenced
FETCH_PROWJOB_SKILL="/tmp/ai-helpers/plugins/ci/skills/fetch-prowjob-json/SKILL.md"
FETCH_PROWJOB_CONTENT=""
if [[ -f "$FETCH_PROWJOB_SKILL" ]]; then
  FETCH_PROWJOB_CONTENT=$(cat "$FETCH_PROWJOB_SKILL")
fi

echo "Skill files loaded."

# ---------------------------------------------------------------------------
# 4. Extract failed test names from GCS build-log
# ---------------------------------------------------------------------------
echo "Prow job URL: $PROW_JOB_URL"

# Download test step build-log from GCS to extract failed test names
FAILED_TESTS=""
for STEP_NAME in hypershift-aws-run-e2e-external hypershift-azure-run-e2e hypershift-aws-run-e2e; do
  BUILD_LOG_URL="${ARTIFACTS_BASE}/${STEP_NAME}/build-log.txt"
  BUILD_LOG_CONTENT=$(curl -sL "$BUILD_LOG_URL" 2>/dev/null | tail -200 || true)
  if [[ -n "$BUILD_LOG_CONTENT" ]]; then
    FAILED_TESTS=$(echo "$BUILD_LOG_CONTENT" | grep -oP '(?<=--- FAIL: )\S+' 2>/dev/null | head -10 || true)
    if [[ -n "$FAILED_TESTS" ]]; then
      echo "Extracted failed tests from ${STEP_NAME}/build-log.txt"
      break
    fi
  fi
done

if [[ -z "$FAILED_TESTS" ]]; then
  FAILED_TESTS="unknown-test-failure"
fi

echo "Failed tests found:"
echo "$FAILED_TESTS" | head -5 | sed 's/^/  - /'

# Pick the first failed test for the primary analysis
FIRST_FAILED_TEST=$(echo "$FAILED_TESTS" | head -1)

# ---------------------------------------------------------------------------
# 5. Run Claude with the real skill
# ---------------------------------------------------------------------------

# Build the system prompt from skill content
SYSTEM_PROMPT="You are analyzing a CI test failure using the Prow Job Analyze Test Failure skill.

IMPORTANT CI CONTEXT:
- You are running inside the CI job itself as a post-step.
- This step's artifact directory is: ${ARTIFACT_DIR}
- Other steps' artifacts (build-log, JUnit, intervals) are available via GCS at: ${PROW_JOB_URL}
- You have network access to download artifacts from GCS using curl or gcloud.
- Use --fast mode (skip must-gather prompting — do NOT use AskUserQuestion).
- Write the final analysis report to: ${ARTIFACT_DIR}/failure-analysis.md
- Do NOT prompt for JIRA export — just write the markdown analysis.

REFERENCED SKILLS:
${SKILL_CONTENT}

DEPENDENT SKILL - Fetch ProwJob JSON:
${FETCH_PROWJOB_CONTENT}"

# Build the user prompt with the job URL and test name
USER_PROMPT="${PROW_JOB_URL} ${FIRST_FAILED_TEST} --fast"

# If multiple tests failed, add them as additional context
ADDITIONAL_TESTS=$(echo "$FAILED_TESTS" | tail -n +2 | head -9)
if [[ -n "$ADDITIONAL_TESTS" ]]; then
  USER_PROMPT="${USER_PROMPT}

Additional failed tests in this job (analyze the primary test above, but mention these):
${ADDITIONAL_TESTS}"
fi

echo ""
echo "Running Claude with /ci:prow-job-analyze-test-failure skill..."
echo "Primary test: $FIRST_FAILED_TEST"
echo ""

set +e
claude -p "$USER_PROMPT" \
  --system-prompt "$SYSTEM_PROMPT" \
  --allowedTools "Bash Read Write Grep Glob WebFetch" \
  --max-turns 30 \
  --model "$CLAUDE_MODEL" \
  --verbose \
  --output-format stream-json \
  2> "${ARTIFACT_DIR}/claude-failure-analysis.log" \
  | tee "${ARTIFACT_DIR}/claude-failure-analysis.json"
CLAUDE_EXIT=$?
set -e

# ---------------------------------------------------------------------------
# 6. Extract token usage and generate HTML report
# ---------------------------------------------------------------------------

# Extract token usage
TOKENS_JSON=$(grep '"type":"result"' "${ARTIFACT_DIR}/claude-failure-analysis.json" 2>/dev/null \
  | head -1 \
  | jq '{
      total_cost_usd: (.total_cost_usd // 0),
      duration_ms: (.duration_ms // 0),
      num_turns: (.num_turns // 0),
      input_tokens: (.usage.input_tokens // 0),
      output_tokens: (.usage.output_tokens // 0),
      cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
      cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0)
    }' 2>/dev/null \
  || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}')

COST=$(echo "$TOKENS_JSON" | jq -r '.total_cost_usd // 0')
DURATION_MS=$(echo "$TOKENS_JSON" | jq -r '.duration_ms // 0')
DURATION_S=$((DURATION_MS / 1000))
NUM_TURNS=$(echo "$TOKENS_JSON" | jq -r '.num_turns // 0')
INPUT_TOKENS=$(echo "$TOKENS_JSON" | jq -r '.input_tokens // 0')
OUTPUT_TOKENS=$(echo "$TOKENS_JSON" | jq -r '.output_tokens // 0')

# Read the markdown analysis if it was written
ANALYSIS_MD=""
if [[ -f "${ARTIFACT_DIR}/failure-analysis.md" ]]; then
  ANALYSIS_MD=$(cat "${ARTIFACT_DIR}/failure-analysis.md")
fi

# Extract Claude text output
jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' \
  "${ARTIFACT_DIR}/claude-failure-analysis.json" \
  > "${ARTIFACT_DIR}/claude-failure-analysis-text.txt" 2>/dev/null || true

# Save token usage to SHARED_DIR for potential report aggregation
echo "$TOKENS_JSON" > "${SHARED_DIR}/claude-failure-analysis-tokens.json" 2>/dev/null || true

# Generate HTML report
cat > "${ARTIFACT_DIR}/failure-analysis-report.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>E2E Failure Analysis Report</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 960px; margin: 0 auto; padding: 20px; background: #f5f5f5; }
  .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.12); }
  h1 { color: #d32f2f; }
  h2 { color: #333; border-bottom: 2px solid #eee; padding-bottom: 8px; }
  .meta { color: #666; font-size: 14px; }
  .meta span { margin-right: 20px; }
  .cost { color: #1565c0; font-weight: bold; }
  pre { background: #263238; color: #eeffff; padding: 16px; border-radius: 4px; overflow-x: auto; white-space: pre-wrap; }
  .analysis { line-height: 1.6; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: bold; }
  .badge-fail { background: #ffcdd2; color: #c62828; }
</style>
</head>
<body>
HTMLEOF

cat >> "${ARTIFACT_DIR}/failure-analysis-report.html" <<EOF
<h1>E2E Failure Analysis Report</h1>
<div class="card">
  <h2>Job Information</h2>
  <div class="meta">
    <span><strong>Job:</strong> ${JOB_NAME}</span><br>
    <span><strong>Build ID:</strong> ${BUILD_ID}</span><br>
    <span><strong>Prow URL:</strong> <a href="${PROW_JOB_URL}">${PROW_JOB_URL}</a></span><br>
    <span><strong>Status:</strong> <span class="badge badge-fail">FAILURES DETECTED</span></span>
  </div>
</div>

<div class="card">
  <h2>Analysis Cost</h2>
  <div class="meta">
    <span><strong>Model:</strong> ${CLAUDE_MODEL}</span>
    <span><strong>Turns:</strong> ${NUM_TURNS}</span>
    <span><strong>Duration:</strong> ${DURATION_S}s</span>
    <span class="cost">Cost: \$${COST}</span><br>
    <span><strong>Input tokens:</strong> ${INPUT_TOKENS}</span>
    <span><strong>Output tokens:</strong> ${OUTPUT_TOKENS}</span>
  </div>
</div>

<div class="card">
  <h2>Analysis</h2>
  <div class="analysis">
    <pre>${ANALYSIS_MD:-"Analysis not available. Check claude-failure-analysis.log for errors."}</pre>
  </div>
</div>

</body>
</html>
EOF

# ---------------------------------------------------------------------------
# 7. Post PR comment with link to report (presubmit jobs only)
# ---------------------------------------------------------------------------
if [[ "$JOB_TYPE" == "presubmit" ]] && [[ -n "$PULL_NUMBER" ]] && [[ -n "${REPO_OWNER}" ]] && [[ -n "${REPO_NAME}" ]]; then
  echo "Posting failure analysis comment to PR #${PULL_NUMBER}..."

  # Generate GitHub App token
  GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"
  APP_ID_FILE="${GITHUB_APP_CREDS_DIR}/app-id"
  PRIVATE_KEY_FILE="${GITHUB_APP_CREDS_DIR}/private-key"
  INSTALLATION_ID_FILE="${GITHUB_APP_CREDS_DIR}/o-h-installation-id"

  if [[ -f "$APP_ID_FILE" ]] && [[ -f "$PRIVATE_KEY_FILE" ]] && [[ -f "$INSTALLATION_ID_FILE" ]]; then
    APP_ID=$(cat "$APP_ID_FILE")
    INSTALL_ID=$(cat "$INSTALLATION_ID_FILE")

    # Disable tracing due to token handling
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    NOW=$(date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

    GITHUB_TOKEN=$(curl -s -X POST \
      -H "Authorization: Bearer ${JWT}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
      | jq -r '.token')

    $WAS_TRACING && set -x

    if [[ -n "$GITHUB_TOKEN" ]] && [[ "$GITHUB_TOKEN" != "null" ]]; then
      export GITHUB_TOKEN

      # Construct the report URL (artifacts will be uploaded to GCS after post steps complete)
      # The step name in the artifact path matches the test name from ci-operator config
      # For presubmit jobs, we need to figure out the test target name
      REPORT_URL="${ARTIFACTS_BASE}/hypershift-analyze-e2e-failure/artifacts/failure-analysis-report.html"

      # Build a concise summary for the PR comment
      FAILED_TEST_LIST=$(echo "$FAILED_TESTS" | head -5 | sed 's/^/- `/' | sed 's/$/`/')
      COMMENT_BODY="$(cat <<COMMENTEOF
### AI Test Failure Analysis

**Job**: \`${JOB_NAME}\` | **Build**: \`${BUILD_ID}\` | **Cost**: \$${COST}

<details>
<summary>Failed tests</summary>

${FAILED_TEST_LIST}

</details>

[View full analysis report](${REPORT_URL})

---
<sub>Generated by [hypershift-analyze-e2e-failure](https://github.com/openshift/release/tree/main/ci-operator/step-registry/hypershift/analyze-e2e-failure) post-step using Claude ${CLAUDE_MODEL}</sub>
COMMENTEOF
)"

      gh pr comment "$PULL_NUMBER" \
        --repo "${REPO_OWNER}/${REPO_NAME}" \
        --body "$COMMENT_BODY" 2>/dev/null \
        && echo "PR comment posted successfully" \
        || echo "Warning: Failed to post PR comment"
    else
      echo "Warning: Could not generate GitHub App token — skipping PR comment"
    fi
  else
    echo "Warning: GitHub App credentials not available — skipping PR comment"
  fi
else
  echo "Not a presubmit job or missing PR info — skipping PR comment"
fi

echo ""
echo "=== Failure Analysis Complete ==="
echo "Claude exit code: $CLAUDE_EXIT"
echo "Cost: \$${COST}"
echo "Duration: ${DURATION_S}s"
echo "Report: ${ARTIFACT_DIR}/failure-analysis-report.html"
echo "Analysis: ${ARTIFACT_DIR}/failure-analysis.md"

# Always exit 0 — this is a best-effort post step
exit 0
