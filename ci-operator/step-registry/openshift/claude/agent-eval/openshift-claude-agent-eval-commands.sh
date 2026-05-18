#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-agent-eval"
echo "Model: ${CLAUDE_MODEL}"
echo "Eval model: ${EVAL_MODEL}"
echo "Judge model: ${EVAL_JUDGE_MODEL}"

# Disable tracing for credential handling
set +x

# -----------------------------------------------------------------------
# Install dependencies
# -----------------------------------------------------------------------
echo "Installing mlflow..."
pip install --quiet mlflow 2>&1 | tail -1
echo "mlflow installed."

# Start local MLflow server in background
echo "Starting local MLflow server on port ${MLFLOW_PORT}..."
export MLFLOW_TRACKING_URI="http://127.0.0.1:${MLFLOW_PORT}"
mlflow server --port "${MLFLOW_PORT}" --host 127.0.0.1 &
MLFLOW_PID=$!

for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${MLFLOW_PORT}/health" >/dev/null 2>&1; then
        echo "MLflow server ready (PID ${MLFLOW_PID})."
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Warning: MLflow server did not become ready in 30s. Continuing anyway."
    fi
    sleep 1
done

# -----------------------------------------------------------------------
# Install agent-eval-harness plugin
# -----------------------------------------------------------------------
echo "Installing agent-eval-harness plugin..."
claude plugin marketplace add opendatahub-io/skills-registry
claude plugin install agent-eval-harness@opendatahub-skills
echo "agent-eval-harness plugin installed."

# -----------------------------------------------------------------------
# Presubmit: detect changed skills
# -----------------------------------------------------------------------
if [[ "${JOB_TYPE:-}" == "presubmit" ]] && [[ -z "${EVAL_SKILLS}" ]]; then
    echo "Presubmit detected. Scanning for changed skills..."
    echo "Base SHA: ${PULL_BASE_SHA:-unknown}"
    echo "Head SHA: ${PULL_PULL_SHA:-unknown}"

    if [[ -n "${PULL_BASE_SHA:-}" ]] && [[ -n "${PULL_PULL_SHA:-}" ]]; then
        CHANGED_SKILLS=$(git diff --name-only "${PULL_BASE_SHA}...${PULL_PULL_SHA}" | \
            grep -E '^plugins/[^/]+/skills/' | \
            sed -E 's|^plugins/([^/]+)/skills/([^/]+)/.*|\1:\2|' | \
            sort -u | tr '\n' ',' | sed 's/,$//' || true)

        if [[ -z "${CHANGED_SKILLS}" ]]; then
            echo "No skill directories changed in this PR. Skipping evaluation."
            exit 0
        fi

        EVAL_SKILLS="${CHANGED_SKILLS}"
        echo "Detected changed skills: ${EVAL_SKILLS}"
    else
        echo "Warning: PULL_BASE_SHA or PULL_PULL_SHA not set. Running all evals."
    fi
fi

# -----------------------------------------------------------------------
# Artifact copy trap
# -----------------------------------------------------------------------
copy_artifacts() {
    echo "Copying artifacts..."
    find . -name "*.html" -path "*/eval/*" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
    find . -name "summary.yaml" -path "*/eval/*" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
    find . -name "*.json" -path "*/eval/*" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
    find . -name "eval-summary-*.html" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true

    # Copy MLflow data
    if [[ -d "mlruns" ]]; then
        tar -czf "${ARTIFACT_DIR}/mlflow-data.tar.gz" mlruns/ 2>/dev/null || true
    fi

    # Archive Claude session for continue-session support
    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi

    # Stop MLflow server
    if [[ -n "${MLFLOW_PID:-}" ]]; then
        kill "${MLFLOW_PID}" 2>/dev/null || true
    fi
}
trap copy_artifacts EXIT TERM INT

# -----------------------------------------------------------------------
# Workaround: --continue + -p is broken (anthropics/claude-code#42376).
# -----------------------------------------------------------------------
export CLAUDE_CODE_ENTRYPOINT=sdk-cli

# -----------------------------------------------------------------------
# Run eval-setup
# -----------------------------------------------------------------------
echo ""
echo "=== Running eval-setup ==="
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob Agent Skill"

claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 20 \
    -p "/eval-setup --skip-mlflow" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval-setup.log" || true

# -----------------------------------------------------------------------
# Build eval-run arguments
# -----------------------------------------------------------------------
SKILL_ARGS=""
if [[ -n "${EVAL_SKILLS}" ]]; then
    SKILL_ARGS="--skill ${EVAL_SKILLS}"
fi

BASELINE_ARGS=""
if [[ -n "${EVAL_BASELINE}" ]]; then
    BASELINE_ARGS="--baseline ${EVAL_BASELINE}"
fi

RUN_ID="ci-$(date +%Y%m%d-%H%M%S)-${EVAL_MODEL}"

# -----------------------------------------------------------------------
# Run eval-run
# -----------------------------------------------------------------------
echo ""
echo "=== Running eval-run ==="
echo "Skills: ${EVAL_SKILLS:-all}"
echo "Run ID: ${RUN_ID}"

EVAL_START=$(date +%s)
EVAL_EXIT=0
timeout 5400 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    -p "/eval-run --model ${EVAL_MODEL} --run-id ${RUN_ID} ${SKILL_ARGS} ${BASELINE_ARGS} ${EVAL_EXTRA_ARGS}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval-run.log" || EVAL_EXIT=$?
EVAL_DURATION=$(( $(date +%s) - EVAL_START ))

echo "eval-run completed with exit code ${EVAL_EXIT} in ${EVAL_DURATION}s"

# -----------------------------------------------------------------------
# Run eval-mlflow to upload results
# -----------------------------------------------------------------------
echo ""
echo "=== Running eval-mlflow ==="

MLFLOW_EXIT=0
timeout 600 claude \
    --model "${CLAUDE_MODEL}" \
    --continue \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 20 \
    -p "/eval-mlflow --action all --run-id ${RUN_ID}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval-mlflow.log" || MLFLOW_EXIT=$?

echo "eval-mlflow completed with exit code ${MLFLOW_EXIT}"

# -----------------------------------------------------------------------
# Generate HTML summary report
# -----------------------------------------------------------------------
echo ""
echo "=== Generating eval summary report ==="

SUMMARY_EXIT=0
timeout 600 claude \
    --model "${CLAUDE_MODEL}" \
    --continue \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 20 \
    -p "Read the eval results (summary.yaml, any judge outputs, and run metadata) and generate a comprehensive standalone HTML report at eval-summary-${RUN_ID}.html. The report should include: an overall pass/fail verdict, per-skill results with judge scores, any regressions detected (if baseline was used), execution metrics (duration, cost, tokens), and a breakdown of any failures with root cause snippets. Use clean, modern styling. Make it self-contained with inline CSS." \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval-summary.log" || SUMMARY_EXIT=$?

echo "Summary report generation completed with exit code ${SUMMARY_EXIT}"

# -----------------------------------------------------------------------
# Generate JUnit XML
# -----------------------------------------------------------------------
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-eval.xml"
TOTAL_DURATION=${EVAL_DURATION}
FAILURE_COUNT=0
TEST_COUNT=1

EVAL_TESTCASE="[sig-claude] Skill evaluation should pass"

if [[ "${EVAL_EXIT}" -ne 0 ]]; then
    FAILURE_COUNT=1
    TESTCASES="  <testcase name=\"${EVAL_TESTCASE}\" time=\"${EVAL_DURATION}\">
    <failure message=\"Eval run failed with exit code ${EVAL_EXIT}\">eval-run exited with code ${EVAL_EXIT}.</failure>
  </testcase>"
else
    TESTCASES="  <testcase name=\"${EVAL_TESTCASE}\" time=\"${EVAL_DURATION}\"/>"
fi

cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-eval" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${TESTCASES}
</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ "${EVAL_EXIT}" -ne 0 ]]; then
    echo "Evaluation failed (exit code ${EVAL_EXIT})."
    exit 1
fi

echo "Evaluation complete."
