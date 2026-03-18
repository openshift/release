#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Only run on presubmit jobs (PRs)
if [[ "${JOB_TYPE:-}" != "presubmit" ]]; then
    echo "Not a presubmit job. Skipping."
    exit 0
fi

# Load GitHub token
set +x
if [[ -f "${GITHUB_TOKEN_PATH}" ]]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
    echo "GitHub token loaded."
else
    echo "No GitHub token found at ${GITHUB_TOKEN_PATH}. Cannot comment on PR."
    exit 0
fi

GCS_BUCKET="test-platform-results"
GCS_PATH="gs://${GCS_BUCKET}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts"
PROW_URL="https://prow.ci.openshift.org/view/gs/${GCS_BUCKET}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"

# Check finished.json for each step to find failures
echo "Checking for failed steps..."
FAILED_STEPS=()

while IFS= read -r finished; do
    result=$(gsutil cat "${finished}" 2>/dev/null | jq -r '.result')
    step_name=$(basename "$(dirname "${finished}")")
    if [[ "${result}" == "FAILURE" ]]; then
        echo "FAILED: ${step_name}"
        FAILED_STEPS+=("${step_name}")
    else
        echo "PASSED: ${step_name}"
    fi
done < <(gsutil ls "${GCS_PATH}/**/finished.json" 2>/dev/null)

if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
    echo "No failed steps found. Skipping analysis."
    exit 0
fi

echo "Found ${#FAILED_STEPS[@]} failed step(s): ${FAILED_STEPS[*]}"

WORKDIR=$(mktemp -d /tmp/claude-analysis-XXXXXX)
cd "${WORKDIR}"

copy_reports() {
    cp "${WORKDIR}"/*.md "${ARTIFACT_DIR}/" 2>/dev/null || true
    cp "${WORKDIR}"/*.html "${ARTIFACT_DIR}/" 2>/dev/null || true

    # Archive Claude session for continue-session support
    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}
trap copy_reports EXIT TERM INT

ALLOWED_TOOLS="Bash Read Grep Glob WebFetch"

PROMPT="You are analyzing a failed CI e2e test for the ${REPO_OWNER}/${REPO_NAME} project.

## Job Information
- PR: https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PULL_NUMBER}
- Prow Job: ${PROW_URL}
- Failed steps: ${FAILED_STEPS[*]}

## Artifacts
The GCS artifacts for this job are at:
${GCS_PATH}/

Use gsutil to browse and read artifacts (build logs, test artifacts, etc.) from the failed steps.

## Instructions
1. Browse the artifacts from the failed steps to understand what went wrong.
2. Fetch the PR diff with: gh pr diff ${PULL_NUMBER} --repo ${REPO_OWNER}/${REPO_NAME}
3. Determine whether the PR's changes are likely responsible for the failure, or if this looks like a pre-existing/flaky issue.
4. Leave a comment on the PR using: gh pr comment ${PULL_NUMBER} --repo ${REPO_OWNER}/${REPO_NAME} --body \"\$(cat <<'COMMENT'
<your analysis>
COMMENT
)\"

Your PR comment should be concise and helpful:
- Start with a one-line summary (e.g. 'The e2e failure appears to be caused by ...' or 'This failure looks unrelated to this PR')
- Include the specific test(s) that failed and why
- If the PR is responsible, point to the specific change that likely caused it
- If the PR is NOT responsible, briefly explain what the actual issue appears to be
- Link to the Prow job: ${PROW_URL}
- Keep it short - engineers are busy

Important: Do NOT make any code changes. Only analyze and comment."

echo "Invoking Claude for failure analysis..."
timeout 600 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 50 \
    -p "${PROMPT}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-analysis.log" || true

echo "Analysis complete."
