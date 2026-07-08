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
#   EVAL_DISCOVER     -- "true" or glob pattern to auto-discover eval configs
#   EVAL_BASELINE     -- run-id of a previous run to compare against
#   EVAL_EXTRA_ARGS   -- additional args passed to /eval-run
#   EVAL_SETUP_SCRIPT -- script to run before eval (e.g. snapshot extraction)
#   CLAUDE_MODEL      -- model for the eval harness orchestrator (default: claude-sonnet-4-6)
#   EVAL_MAX_TURNS    -- max conversation turns for the orchestrator (default: 100)

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-agent-eval"

# Load GitHub token for gh CLI access (same secret as payload-agent)
set +x
if [ -f "${GITHUB_TOKEN_PATH:-}" ]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
    echo "GitHub token loaded."
else
    echo "Warning: GitHub token not found at ${GITHUB_TOKEN_PATH:-<unset>}. gh CLI will run unauthenticated."
fi

# The repo is at /opt/ai-helpers; WORKDIR is /workspace
cd /opt/ai-helpers

echo "Skill model: ${EVAL_MODEL}"

# -----------------------------------------------------------------------
# Build list of eval configs to run (single or discovery mode)
# -----------------------------------------------------------------------
CONFIGS_TO_RUN=()
if [[ -n "${EVAL_DISCOVER}" ]]; then
    if [[ -n "${EVAL_CONFIG}" ]] && [[ "${EVAL_CONFIG}" != "eval.yaml" ]]; then
        echo "ERROR: EVAL_DISCOVER and EVAL_CONFIG are mutually exclusive"
        exit 1
    fi

    # Default discovery pattern: all YAML files directly under */evals/ directories
    DISCOVER_PATTERN="${EVAL_DISCOVER}"
    if [[ "${EVAL_DISCOVER}" == "true" ]]; then
        DISCOVER_PATTERN="plugins/*/evals/*.yaml"
    fi

    echo "=== Discovering eval configs: ${DISCOVER_PATTERN} ==="
    while IFS= read -r config; do
        [[ -n "${config}" ]] && CONFIGS_TO_RUN+=("${config}")
    done < <(find . -path "./${DISCOVER_PATTERN}" -name '*.yaml' ! -path '*/cases/*' | sed 's|^\./||' | sort)

    echo "Found ${#CONFIGS_TO_RUN[@]} eval config(s):"
    printf '  %s\n' "${CONFIGS_TO_RUN[@]}"

    if [[ ${#CONFIGS_TO_RUN[@]} -eq 0 ]]; then
        echo "No eval configs found matching ${DISCOVER_PATTERN}"
        exit 0
    fi

    # Filter to only changed evals when EVAL_CHANGED_ONLY is set
    if [[ "${EVAL_CHANGED_ONLY:-}" == "true" ]] && [[ -n "${PULL_BASE_SHA:-}" ]]; then
        echo ""
        echo "=== Filtering to changed evals ==="
        CHANGED_FILES=$(git diff --name-only "${PULL_BASE_SHA}...HEAD" || true)

        FILTERED=()
        for config in "${CONFIGS_TO_RUN[@]}"; do
            config_name=$(basename "${config}" .yaml)
            config_dir=$(dirname "${config}")

            if echo "${CHANGED_FILES}" | grep -qE "(${config}|${config_dir}/${config_name}/|skills/${config_name}/)"; then
                echo "  MATCH: ${config}"
                FILTERED+=("${config}")
            fi
        done

        if [[ ${#FILTERED[@]} -eq 0 ]]; then
            echo "No eval configs affected by changes, skipping."
            exit 0
        fi
        CONFIGS_TO_RUN=("${FILTERED[@]}")
    fi
else
    echo "Config: ${EVAL_CONFIG}"
    if [[ ! -f "${EVAL_CONFIG}" ]]; then
        echo "ERROR: EVAL_CONFIG not found at ${EVAL_CONFIG}"
        exit 1
    fi
    CONFIGS_TO_RUN=("${EVAL_CONFIG}")
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
# Build common arguments and run evals
# -----------------------------------------------------------------------
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob Agent Skill"
OVERALL_EXIT=0
JUNIT_TESTCASES=""
TOTAL_DURATION=0
FAILURE_COUNT=0
CONFIGS_RUN=0
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-eval.xml"
STEP_START=${SECONDS}
STEP_TIMEOUT=10200  # 2h50m — leave margin within the 3h step limit

write_junit() {
    cat > "${JUNIT_FILE}" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-eval" tests="${CONFIGS_RUN}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${JUNIT_TESTCASES}
</testsuite>
JEOF
}

for config in "${CONFIGS_TO_RUN[@]}"; do
    ELAPSED=$(( SECONDS - STEP_START ))
    if [[ ${ELAPSED} -ge ${STEP_TIMEOUT} ]]; then
        echo "WARNING: approaching step timeout (${ELAPSED}s elapsed), skipping remaining configs."
        break
    fi
    config_name=$(echo "${config}" | sed 's|\.yaml$||' | tr '/' '-')
    config_basename=$(basename "${config}" .yaml)
    echo ""
    echo "========================================"
    echo "=== Running eval: ${config_name} ==="
    echo "========================================"

    RUN_ID="ci-$(date +%Y%m%d-%H%M%S)-${config_name}-${EVAL_MODEL}"

    # Per-config changed-case detection
    CASE_ARGS=""
    if [[ "${EVAL_CHANGED_ONLY:-}" == "true" ]] && [[ -n "${PULL_BASE_SHA:-}" ]]; then
        # In discovery mode, derive cases dir from config path convention
        if [[ -n "${EVAL_DISCOVER}" ]]; then
            CASES_DIR="$(dirname "${config}")/${config_basename}/cases"
        elif [[ -n "${EVAL_CASES_DIR}" ]]; then
            CASES_DIR="${EVAL_CASES_DIR}"
        else
            CASES_DIR=""
        fi

        if [[ -n "${CASES_DIR}" ]] && [[ -d "${CASES_DIR}" ]]; then
            if CASE_CHANGES=$(git diff --name-only "${PULL_BASE_SHA}...HEAD" -- "${CASES_DIR}"); then
                if [[ -n "${CASE_CHANGES}" ]]; then
                    DETECTED=$(echo "${CASE_CHANGES}" | sed "s|^${CASES_DIR}/||" | cut -d'/' -f1 | sort -u | paste -sd, -)
                    echo "Changed cases: ${DETECTED}"
                    CASE_ARGS="--cases ${DETECTED//,/ }"
                fi
            fi
        fi
    fi

    # Skip configs with no changed cases in changed-only mode
    if [[ "${EVAL_CHANGED_ONLY:-}" == "true" ]] && [[ -z "${CASE_ARGS}" ]] && [[ -z "${EVAL_CASES}" ]]; then
        echo "No changed cases for ${config_name}, skipping."
        continue
    fi

    # Include explicit EVAL_CASES if set (single-config mode)
    if [[ -z "${CASE_ARGS}" ]] && [[ -n "${EVAL_CASES}" ]]; then
        CASE_ARGS="--cases ${EVAL_CASES//,/ }"
    fi

    EVAL_RUN_ARGS="--config ${config} --model ${EVAL_MODEL} --run-id ${RUN_ID} --parallelism ${EVAL_PARALLELISM}"
    [[ -n "${CASE_ARGS}" ]] && EVAL_RUN_ARGS="${EVAL_RUN_ARGS} ${CASE_ARGS}"
    [[ -n "${EVAL_BASELINE}" ]] && EVAL_RUN_ARGS="${EVAL_RUN_ARGS} --baseline ${EVAL_BASELINE}"
    [[ -n "${EVAL_EXTRA_ARGS}" ]] && EVAL_RUN_ARGS="${EVAL_RUN_ARGS} ${EVAL_EXTRA_ARGS}"

    echo "Run ID: ${RUN_ID}"
    echo "Args: ${EVAL_RUN_ARGS}"

    EVAL_START=$(date +%s)
    THIS_EXIT=0
    timeout 7200 claude \
        --model "${CLAUDE_MODEL}" \
        --plugin-dir "${EVAL_HARNESS_DIR}" \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns "${EVAL_MAX_TURNS}" \
        -p "/eval-run ${EVAL_RUN_ARGS}" \
        --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-eval-${config_name}.log" || THIS_EXIT=$?
    THIS_DURATION=$(( $(date +%s) - EVAL_START ))
    TOTAL_DURATION=$(( TOTAL_DURATION + THIS_DURATION ))

    TESTCASE="[sig-claude] ${config_name} evaluation"
    if [[ "${THIS_EXIT}" -ne 0 ]]; then
        OVERALL_EXIT=1
        FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
        JUNIT_TESTCASES="${JUNIT_TESTCASES}
  <testcase name=\"${TESTCASE}\" time=\"${THIS_DURATION}\">
    <failure message=\"eval-run failed (exit ${THIS_EXIT})\">eval-run exited with code ${THIS_EXIT}.</failure>
  </testcase>"
    else
        JUNIT_TESTCASES="${JUNIT_TESTCASES}
  <testcase name=\"${TESTCASE}\" time=\"${THIS_DURATION}\"/>"
    fi

    CONFIGS_RUN=$(( CONFIGS_RUN + 1 ))
    echo "=== ${config_name}: completed in ${THIS_DURATION}s (exit ${THIS_EXIT}) ==="

    write_junit
done

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ "${OVERALL_EXIT}" -ne 0 ]]; then
    echo "Evaluation failed."
    exit 1
fi

echo "Evaluation complete."
