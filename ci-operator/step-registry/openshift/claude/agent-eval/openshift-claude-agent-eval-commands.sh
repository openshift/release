#!/bin/bash
#
# Run agent-eval-harness against Claude Code skills.
#
# Required env:
#   EVAL_CONFIG  -- path to eval.yaml (relative to repo root)
#
# Optional env:
#   EVAL_MODEL        -- model for the skill under test (default: claude-sonnet-4-6)
#   EVAL_PARALLELISM  -- number of test cases to run concurrently (default: 1)
#   EVAL_CASES        -- comma-separated list of case IDs to run (default: all)
#   EVAL_BASELINE     -- run-id of a previous run to compare against
#   EVAL_EXTRA_ARGS   -- additional args passed to /eval-run
#   EVAL_SETUP_SCRIPT -- script to run before eval (e.g. snapshot extraction)
#   CLAUDE_MODEL      -- model for the eval harness orchestrator (default: claude-sonnet-4-6)
#   EVAL_MAX_TURNS    -- max conversation turns for the orchestrator (default: 100)

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-agent-eval"

# The repo is at /opt/ai-helpers; WORKDIR is /workspace
cd /opt/ai-helpers

echo "Config: ${EVAL_CONFIG}"
echo "Skill model: ${EVAL_MODEL}"

# -----------------------------------------------------------------------
# Verify eval config exists
# -----------------------------------------------------------------------
if [[ ! -f "${EVAL_CONFIG}" ]]; then
    echo "ERROR: EVAL_CONFIG not found at ${EVAL_CONFIG}"
    exit 1
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
    EVAL_SNAPSHOT_DIR=$(bash "${EVAL_SETUP_SCRIPT}")
    export EVAL_SNAPSHOT_DIR
    echo "Snapshot dir: ${EVAL_SNAPSHOT_DIR}"
fi

# -----------------------------------------------------------------------
# Install plugins
# -----------------------------------------------------------------------
echo ""
echo "=== Installing plugins ==="
EVAL_HARNESS_DIR="/tmp/agent-eval-harness"
git clone --depth 1 https://github.com/opendatahub-io/agent-eval-harness.git "${EVAL_HARNESS_DIR}"
echo "agent-eval-harness cloned."

# -----------------------------------------------------------------------
# Artifact copy trap
# -----------------------------------------------------------------------
copy_artifacts() {
    echo "Copying eval artifacts..."
    RUNS_DIR="${AGENT_EVAL_RUNS_DIR:-eval/runs}"
    if [[ -d "${RUNS_DIR}" ]]; then
        find "${RUNS_DIR}" -name "report.html" -exec cp {} "${ARTIFACT_DIR}/eval-report-summary.html" \; 2>/dev/null || true
        find "${RUNS_DIR}" -name "summary.yaml" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
        find "${RUNS_DIR}" -name "run_result.json" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
        tar -czf "${ARTIFACT_DIR}/eval-runs.tar.gz" "${RUNS_DIR}/" 2>/dev/null || true
    fi

    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        tar -czf "${ARTIFACT_DIR}/claude-sessions.tar.gz" \
            -C "${CLAUDE_HOME}" projects/ 2>/dev/null || true
    fi
}
trap copy_artifacts EXIT TERM INT

# -----------------------------------------------------------------------
# Workaround: --continue + -p is broken (anthropics/claude-code#42376).
# -----------------------------------------------------------------------
export CLAUDE_CODE_ENTRYPOINT=sdk-cli

# -----------------------------------------------------------------------
# Auto-detect changed eval cases from PR diff
# -----------------------------------------------------------------------
if [[ "${EVAL_CHANGED_ONLY}" == "true" ]] && [[ -n "${EVAL_CASES_DIR}" ]] && [[ -z "${EVAL_CASES}" ]]; then
    echo ""
    echo "=== Detecting changed eval cases ==="
    if [[ -z "${PULL_BASE_SHA:-}" ]]; then
        echo "PULL_BASE_SHA not set, running all cases."
    else
        CHANGED_FILES=$(git diff --name-only "${PULL_BASE_SHA}...HEAD" -- "${EVAL_CASES_DIR}" || true)
        if [[ -n "${CHANGED_FILES}" ]]; then
            DETECTED_CASES=$(echo "${CHANGED_FILES}" | sed "s|^${EVAL_CASES_DIR}/||" | cut -d'/' -f1 | sort -u | paste -sd, -)
            echo "Changed cases: ${DETECTED_CASES}"
            EVAL_CASES="${DETECTED_CASES}"
        else
            echo "No changed cases detected in ${EVAL_CASES_DIR}, skipping eval."
            exit 0
        fi
    fi
fi

# -----------------------------------------------------------------------
# Build arguments
# -----------------------------------------------------------------------
RUN_ID="ci-$(date +%Y%m%d-%H%M%S)-${EVAL_MODEL}"
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob Agent Skill"

EVAL_RUN_ARGS="--config ${EVAL_CONFIG} --model ${EVAL_MODEL} --run-id ${RUN_ID} --parallelism ${EVAL_PARALLELISM}"
if [[ -n "${EVAL_CASES}" ]]; then
    EVAL_RUN_ARGS="${EVAL_RUN_ARGS} --cases ${EVAL_CASES//,/ }"
fi
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
    --plugin-dir "${EVAL_HARNESS_DIR}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns "${EVAL_MAX_TURNS}" \
    -p "/eval-run ${EVAL_RUN_ARGS}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval.log" || EVAL_EXIT=$?
EVAL_DURATION=$(( $(date +%s) - EVAL_START ))

echo "eval-run completed in ${EVAL_DURATION}s (exit ${EVAL_EXIT})"

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
