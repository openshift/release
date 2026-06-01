#!/bin/bash
#
# Run agent-eval-harness against Claude Code skills.
#
# Required env:
#   EVAL_CONFIG  -- path to eval.yaml (relative to repo root)
#
# Optional env:
#   EVAL_MODEL        -- model for the skill under test (default: claude-sonnet-4-6)
#   EVAL_JUDGE_MODEL  -- model for LLM judges (default: claude-sonnet-4-6)
#   EVAL_BASELINE     -- run-id of a previous run to compare against
#   EVAL_EXTRA_ARGS   -- additional args passed to /eval-run
#   EVAL_SETUP_SCRIPT -- script to run before eval (e.g. snapshot extraction)
#   CLAUDE_MODEL      -- model for the eval harness orchestrator (default: claude-sonnet-4-6)
#   MLFLOW_PORT       -- port for local MLflow server (default: 5000)

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-agent-eval"
echo "Config: ${EVAL_CONFIG}"
echo "Skill model: ${EVAL_MODEL}"
echo "Judge model: ${EVAL_JUDGE_MODEL}"

# -----------------------------------------------------------------------
# Install dependencies
# -----------------------------------------------------------------------
echo "Installing mlflow..."
python3 -m pip install --quiet 'mlflow==2.20.2' 2>&1 | tail -1
export PATH="$HOME/.local/bin:$PATH"
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
    if ! kill -0 "${MLFLOW_PID}" 2>/dev/null; then
        echo "ERROR: MLflow server crashed."
        exit 1
    fi
    if [[ $i -eq 30 ]]; then
        echo "ERROR: MLflow server did not become ready in 30s."
        exit 1
    fi
    sleep 1
done

# -----------------------------------------------------------------------
# Generate hello-world smoke test if no eval config exists
# -----------------------------------------------------------------------
if [[ ! -f "${EVAL_CONFIG}" ]]; then
    echo "EVAL_CONFIG not found at ${EVAL_CONFIG}, generating hello-world smoke test..."
    EVAL_SETUP_SCRIPT=""
    mkdir -p "$(dirname "${EVAL_CONFIG}")"
    cat > "${EVAL_CONFIG}" <<'EVALEOF'
name: hello-world-smoke-test
description: Smoke test for eval infrastructure using hello-world plugin
skill: hello-world:echo

execution:
  mode: case
  arguments: "{name}"
  timeout: 60

runner:
  type: claude-code
  plugin_dirs:
    - plugins/hello-world

dataset:
  path: eval/cases/hello-world

outputs:
  files:
    - "*.txt"

traces:
  stdout: true

judges:
  greeting_correct:
    type: check
    check: |
      stdout = record.get("outputs", {}).get("stdout", "")
      name = record.get("inputs", {}).get("name", "world")
      expected = f"Hello {name}"
      if expected.lower() in stdout.lower():
          score = 1.0
          rationale = f"Found expected greeting: {expected}"
      else:
          score = 0.0
          rationale = f"Expected '{expected}' in output, got: {stdout[:200]}"

thresholds:
  greeting_correct:
    min_pass_rate: 1.0
EVALEOF

    mkdir -p eval/cases/hello-world/case-001-default
    cat > eval/cases/hello-world/case-001-default/input.yaml <<'CASEEOF'
name: "world"
CASEEOF

    mkdir -p eval/cases/hello-world/case-002-named
    cat > eval/cases/hello-world/case-002-named/input.yaml <<'CASEEOF'
name: "Alice"
CASEEOF

    echo "Generated smoke test config at ${EVAL_CONFIG}"
fi

# -----------------------------------------------------------------------
# Run optional setup script (e.g. extract snapshots, populate fixtures)
# -----------------------------------------------------------------------
if [[ -n "${EVAL_SETUP_SCRIPT}" ]]; then
    if [[ ! -f "${EVAL_SETUP_SCRIPT}" ]]; then
        echo "ERROR: EVAL_SETUP_SCRIPT not found: ${EVAL_SETUP_SCRIPT}"
        exit 1
    fi
    echo ""
    echo "=== Running setup script: ${EVAL_SETUP_SCRIPT} ==="
    bash "${EVAL_SETUP_SCRIPT}"
fi

# -----------------------------------------------------------------------
# Install plugins
# -----------------------------------------------------------------------
echo ""
echo "=== Installing plugins ==="
git config --global url."https://github.com/".insteadOf "git@github.com:"
claude plugin marketplace add opendatahub-io/skills-registry
claude plugin install agent-eval-harness@opendatahub-skills
echo "agent-eval-harness plugin installed."

# -----------------------------------------------------------------------
# Artifact copy trap
# -----------------------------------------------------------------------
copy_artifacts() {
    echo "Copying eval artifacts..."
    if [[ -d "${AGENT_EVAL_RUNS_DIR:-eval/runs}" ]]; then
        find "${AGENT_EVAL_RUNS_DIR:-eval/runs}" -name "report.html" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
        find "${AGENT_EVAL_RUNS_DIR:-eval/runs}" -name "summary.yaml" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
        find "${AGENT_EVAL_RUNS_DIR:-eval/runs}" -name "run_result.json" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
    fi
    find . -name "eval-summary-*.html" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true

    # Copy MLflow data
    if [[ -d "mlruns" ]]; then
        tar -czf "${ARTIFACT_DIR}/mlflow-data.tar.gz" mlruns/ 2>/dev/null || true
    fi

    # Archive Claude session for continue-session support
    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" \
            -C "${CLAUDE_HOME}" projects/ 2>/dev/null && \
            touch "${SHARED_DIR}/claude-session-available" || true
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
# Build arguments
# -----------------------------------------------------------------------
RUN_ID="ci-$(date +%Y%m%d-%H%M%S)-${EVAL_MODEL}"
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob Agent Skill"

EVAL_RUN_ARGS="--config ${EVAL_CONFIG} --model ${EVAL_MODEL} --run-id ${RUN_ID}"
if [[ -n "${EVAL_BASELINE}" ]]; then
    EVAL_RUN_ARGS="${EVAL_RUN_ARGS} --baseline ${EVAL_BASELINE}"
fi
if [[ -n "${EVAL_EXTRA_ARGS}" ]]; then
    EVAL_RUN_ARGS="${EVAL_RUN_ARGS} ${EVAL_EXTRA_ARGS}"
fi

# -----------------------------------------------------------------------
# Run evaluation
# -----------------------------------------------------------------------
echo ""
echo "=== Running eval ==="
echo "Run ID: ${RUN_ID}"
echo "Args: ${EVAL_RUN_ARGS}"

EVAL_START=$(date +%s)
EVAL_EXIT=0
timeout 7200 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    -p "/eval-run ${EVAL_RUN_ARGS}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval.log" || EVAL_EXIT=$?
EVAL_DURATION=$(( $(date +%s) - EVAL_START ))

echo "eval-run completed in ${EVAL_DURATION}s (exit ${EVAL_EXIT})"

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
    -p "/eval-mlflow --action all --run-id ${RUN_ID} --config ${EVAL_CONFIG}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval-mlflow.log" || MLFLOW_EXIT=$?

echo "eval-mlflow completed with exit code ${MLFLOW_EXIT}"

# -----------------------------------------------------------------------
# Generate JUnit XML
# -----------------------------------------------------------------------
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-eval.xml"
FAILURE_COUNT=0
TESTCASE="[sig-claude] Skill evaluation should pass"

if [[ "${EVAL_EXIT}" -ne 0 ]]; then
    FAILURE_COUNT=1
    TESTCASES="  <testcase name=\"${TESTCASE}\" time=\"${EVAL_DURATION}\">
    <failure message=\"eval-run failed (exit ${EVAL_EXIT})\">eval-run exited with code ${EVAL_EXIT}.</failure>
  </testcase>"
else
    TESTCASES="  <testcase name=\"${TESTCASE}\" time=\"${EVAL_DURATION}\"/>"
fi

cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-eval" tests="1" failures="${FAILURE_COUNT}" time="${EVAL_DURATION}">
${TESTCASES}
</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ "${EVAL_EXIT}" -ne 0 ]]; then
    echo "Evaluation failed."
    exit 1
fi

echo "Evaluation complete."
