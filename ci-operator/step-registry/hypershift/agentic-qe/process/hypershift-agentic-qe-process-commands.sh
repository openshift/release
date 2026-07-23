#!/bin/bash
set -euo pipefail

echo "=== HyperShift Agent QE Process ==="

# Management cluster kubeconfig (from pre phase)
MGMT_KUBECONFIG="${SHARED_DIR}/kubeconfig"
# Guest cluster kubeconfig (from hypershift-aws-create)
GUEST_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
# Cluster name (from hypershift-aws-create)
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")

echo "Management cluster: $(KUBECONFIG=$MGMT_KUBECONFIG oc whoami --show-server)"
echo "HostedCluster name: $CLUSTER_NAME"

# Set KUBECONFIG to guest cluster by default for test execution
export KUBECONFIG="$GUEST_KUBECONFIG"
echo "Guest cluster: $(oc whoami --show-server)"

# Determine PR number from Prow environment
PR_NUMBER="${PULL_NUMBER:-}"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PULL_NUMBER not set — this job must run as a presubmit"
  exit 1
fi

REPO_ORG="${REPO_OWNER:-openshift}"
REPO_NAME="${REPO_NAME:-hypershift}"
echo "Processing PR #${PR_NUMBER} from ${REPO_ORG}/${REPO_NAME}"

# Verify the job was triggered by a core-approver
echo "Checking who triggered the job..."
TRIGGER_USER=$(curl -s "https://api.github.com/repos/${REPO_ORG}/${REPO_NAME}/issues/${PR_NUMBER}/comments?per_page=100&direction=desc" \
  | jq -r '[.[] | select(.body | test("/test\\s+(|.* )agentic-qe"))] | last | .user.login // empty')

if [ -z "$TRIGGER_USER" ]; then
  echo "WARNING: Could not determine who triggered the job"
  echo "Exiting — only core-approvers can trigger this job"
  exit 0
fi

echo "Job triggered by: $TRIGGER_USER"

# Fetch OWNERS_ALIASES and check if user is in the core-approvers group
CORE_APPROVERS=$(curl -s "https://raw.githubusercontent.com/${REPO_ORG}/${REPO_NAME}/main/OWNERS_ALIASES" \
  | yq -r '.aliases.core-approvers[]' 2>/dev/null \
  || curl -s "https://raw.githubusercontent.com/${REPO_ORG}/${REPO_NAME}/main/OWNERS_ALIASES" \
    | python3 -c "import sys,yaml; print('\n'.join(yaml.safe_load(sys.stdin)['aliases']['core-approvers']))" 2>/dev/null \
  || echo "")

if [ -z "$CORE_APPROVERS" ]; then
  echo "WARNING: Could not fetch core-approvers from OWNERS_ALIASES"
  exit 0
fi

if ! echo "$CORE_APPROVERS" | grep -qx "$TRIGGER_USER"; then
  echo "ERROR: $TRIGGER_USER is not a core-approver"
  echo "Only core-approvers can trigger the agentic-qe job:"
  echo "$CORE_APPROVERS" | sed 's/^/  - /'
  exit 0
fi

echo "Verified: $TRIGGER_USER is a core-approver"

# Clone the PR head
echo "Cloning repository at PR head..."
git clone "https://github.com/${REPO_ORG}/${REPO_NAME}.git" /tmp/hypershift
cd /tmp/hypershift
git fetch origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
git checkout "pr-${PR_NUMBER}"

# Discover test plan files changed/added by this PR
echo "Discovering test plan files changed by PR #${PR_NUMBER}..."
CHANGED_PLANS=$(git diff --name-only --diff-filter=ACM "origin/main...HEAD" -- "${TEST_PLAN_DIR}/" || true)

if [ -z "$CHANGED_PLANS" ]; then
  echo "No test plan files changed/added in ${TEST_PLAN_DIR}/"
  echo "Nothing to do."
  exit 0
fi

echo "Found test plan files:"
echo "$CHANGED_PLANS" | sed 's/^/  - /'

PASS_COUNT=0
FAIL_COUNT=0

# Process each test plan
for PLAN_FILE in $CHANGED_PLANS; do
  if [ ! -f "$PLAN_FILE" ]; then
    echo "Warning: $PLAN_FILE not found, skipping"
    continue
  fi

  PLAN_BASENAME=$(basename "$PLAN_FILE" | sed 's/\.[^.]*$//')
  RESULT_FILE="/tmp/test-result-${PLAN_BASENAME}.json"

  echo ""
  echo "=========================================="
  echo "Executing test plan: $PLAN_FILE"
  echo "=========================================="

  PLAN_CONTENT=$(cat "$PLAN_FILE")

  PROMPT="You are a QE engineer executing a test plan against a real OpenShift environment.

ENVIRONMENT:
- Management cluster kubeconfig: ${MGMT_KUBECONFIG}
- Guest cluster kubeconfig (default): ${GUEST_KUBECONFIG}
- HostedCluster name: ${CLUSTER_NAME}
- HostedCluster namespace: clusters

The default KUBECONFIG points to the guest (hosted) cluster.
To run commands against the management cluster, use: KUBECONFIG=${MGMT_KUBECONFIG} oc <command>

TEST PLAN:
${PLAN_CONTENT}

INSTRUCTIONS:
- Execute the test plan step by step using oc/kubectl commands.
- Report pass/fail for each step.
- If a step fails, continue executing remaining steps and report all results.
- Do NOT delete the HostedCluster or NodePool resources — cleanup is handled separately.
- SECURITY: Do NOT run commands that reveal credentials.

RESULT FILE (MANDATORY):
When you have finished executing ALL steps, you MUST write a JSON result file to ${RESULT_FILE} using the Write tool.
The file MUST contain:
{
  \"passed\": true or false,
  \"total\": <number of steps executed>,
  \"passed_count\": <number of steps that passed>,
  \"failed_count\": <number of steps that failed>,
  \"steps\": [
    {\"name\": \"step description\", \"passed\": true or false, \"detail\": \"brief result or error\"}
  ]
}
Set \"passed\" to true ONLY if ALL steps passed. Set it to false if ANY step failed.
This file is required — the job result depends on it."

  # Remove any stale result file
  rm -f "$RESULT_FILE"

  set +e
  claude -p "$PROMPT" \
    --allowedTools "Bash Read Write Edit Grep Glob" \
    --max-turns 100 \
    --model "$CLAUDE_MODEL" \
    --verbose \
    --output-format stream-json \
    2> "${ARTIFACT_DIR}/claude-${PLAN_BASENAME}.log" \
    | tee "${ARTIFACT_DIR}/claude-${PLAN_BASENAME}.json"
  CLAUDE_EXIT=$?
  set -e

  # Extract text output
  jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' \
    "${ARTIFACT_DIR}/claude-${PLAN_BASENAME}.json" \
    > "${SHARED_DIR}/claude-${PLAN_BASENAME}-output.txt" 2>/dev/null || true

  # Extract token usage summary for report step
  grep '"type":"result"' "${ARTIFACT_DIR}/claude-${PLAN_BASENAME}.json" \
    | head -1 \
    | jq '{
        total_cost_usd: (.total_cost_usd // 0),
        duration_ms: (.duration_ms // 0),
        num_turns: (.num_turns // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
        cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0),
        model_usage: (.modelUsage // {}),
        model: ((.modelUsage // {} | keys | first) // "unknown")
      }' > "${SHARED_DIR}/claude-${PLAN_BASENAME}-tokens.json" 2>/dev/null \
    || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}' \
      > "${SHARED_DIR}/claude-${PLAN_BASENAME}-tokens.json"

  # Extract tool call and error summaries
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' \
    "${ARTIFACT_DIR}/claude-${PLAN_BASENAME}.json" 2>/dev/null \
    | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-${PLAN_BASENAME}-tools.txt" 2>/dev/null || true
  jq -r 'select(.type == "user") | .tool_use_result | select(type == "string") | select(startswith("Error:"))' \
    "${ARTIFACT_DIR}/claude-${PLAN_BASENAME}.json" 2>/dev/null \
    | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-${PLAN_BASENAME}-errors.txt" 2>/dev/null || true

  # Determine pass/fail from the result file
  if [ $CLAUDE_EXIT -ne 0 ]; then
    echo "Claude crashed (exit code: $CLAUDE_EXIT) — marking test plan as failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  elif [ ! -f "$RESULT_FILE" ]; then
    echo "WARNING: Claude did not write result file — marking test plan as failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    # Copy result file to SHARED_DIR for report step
    cp "$RESULT_FILE" "${SHARED_DIR}/test-result-${PLAN_BASENAME}.json"
    cp "$RESULT_FILE" "${ARTIFACT_DIR}/test-result-${PLAN_BASENAME}.json"

    PLAN_PASSED=$(jq -r '.passed' "$RESULT_FILE" 2>/dev/null || echo "false")
    PLAN_TOTAL=$(jq -r '.total // 0' "$RESULT_FILE" 2>/dev/null || echo "0")
    PLAN_PASSED_CT=$(jq -r '.passed_count // 0' "$RESULT_FILE" 2>/dev/null || echo "0")
    PLAN_FAILED_CT=$(jq -r '.failed_count // 0' "$RESULT_FILE" 2>/dev/null || echo "0")

    echo "Test plan result: passed=${PLAN_PASSED} (${PLAN_PASSED_CT}/${PLAN_TOTAL} steps passed, ${PLAN_FAILED_CT} failed)"

    if [ "$PLAN_PASSED" = "true" ]; then
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi
done

echo ""
echo "=== Test Plan Execution Summary ==="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo "===================================="

if [ $FAIL_COUNT -gt 0 ]; then
  exit 1
fi
