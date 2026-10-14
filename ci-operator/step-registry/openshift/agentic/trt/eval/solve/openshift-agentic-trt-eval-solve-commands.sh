#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Solve ==="

[[ -f "${SHARED_DIR}/github-app-auth.sh" ]] || {
    echo "ERROR: ${SHARED_DIR}/github-app-auth.sh not found — github-app-auth step must run first"
    exit 1
}
# shellcheck source=/dev/null
source "${SHARED_DIR}/github-app-auth.sh"
load_github_tokens
configure_github_git_credentials

# --- Read case list ---
mapfile -t CASE_LIST < "${SHARED_DIR}/eval-cases"
MAX_PARALLEL="${EVAL_PARALLELISM:-5}"
echo "Cases (${#CASE_LIST[@]}): ${CASE_LIST[*]} | Parallelism: ${MAX_PARALLEL}"

# --- Clone repo template ---
TEMPLATE_DIR="/tmp/eval-repo-template"
git clone "https://github.com/${UPSTREAM_REPO}.git" "${TEMPLATE_DIR}"
git -C "${TEMPLATE_DIR}" config user.name "openshift-trt"
git -C "${TEMPLATE_DIR}" config user.email "openshift-trt@redhat.com"
git -C "${TEMPLATE_DIR}" remote add fork "https://github.com/${FORK_REPO}.git"

# --- Shared setup (once) ---
echo "Running setup script: ${SETUP_SCRIPT}..."
cd "${TEMPLATE_DIR}"
# shellcheck source=/dev/null
source "${TEMPLATE_DIR}/${SETUP_SCRIPT}"

echo "Installing agent tooling (OpenCode harness)..."
[[ -f "${SHARED_DIR}/trt-agent.sh" ]] || {
    echo "ERROR: ${SHARED_DIR}/trt-agent.sh not found — eval init step must run first"
    exit 1
}
# shellcheck source=/dev/null
source "${SHARED_DIR}/trt-agent.sh"
trt_resolve_model
echo "Agent model: ${TRT_MODEL} (requested: '${TRT_MODEL_REQUESTED:-}')"
trt_opencode_setup

# --- Artifact collection ---
REAL_SHARED_DIR="${SHARED_DIR}"
copy_artifacts() {
    echo "Copying artifacts..."
    for case_name in "${CASE_LIST[@]}"; do
        mkdir -p "${ARTIFACT_DIR}/${case_name}"
        if [[ -d "/workspace/${case_name}/artifacts" ]]; then
            cp "/workspace/${case_name}/artifacts/"* "${ARTIFACT_DIR}/${case_name}/" 2>/dev/null || true
        fi
    done
    podman logs sippy-postgres > "${ARTIFACT_DIR}/postgres.log" 2>&1 || true
    if [[ -d "${HOME}/.local/share/opencode" ]]; then
        tar -czf "${ARTIFACT_DIR}/opencode-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" \
            -C "${HOME}/.local/share" opencode/ 2>/dev/null || true
    fi
}
trap copy_artifacts EXIT TERM INT

# --- Per-case dispatch ---
# Each subshell gets a temp SHARED_DIR with standard filenames the solver expects:
#   reads:  gh-fork-token, gh-upstream-token, jira-issue-key, jira-issue.json, eval-base-branch, eval-case
#   writes: claude-branch, pr-number, pr-description.md
RESULTS_DIR="/tmp/eval-results"
mkdir -p "${RESULTS_DIR}"
RUNNING=0

for case_name in "${CASE_LIST[@]}"; do
    CASE_WORKDIR="/workspace/${case_name}"
    BASE_BRANCH=$(cat "${REAL_SHARED_DIR}/${case_name}.eval-base-branch")

    (
        # Build a per-case SHARED_DIR with standard filenames
        CASE_SHARED=$(mktemp -d)
        for f in jira-issue-key jira-issue.json eval-base-branch eval-expected-branch eval-case; do
            cp "${REAL_SHARED_DIR}/${case_name}.${f}" "${CASE_SHARED}/${f}"
        done
        cp "${REAL_SHARED_DIR}/gh-fork-token" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/gh-upstream-token" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/trt-agent.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/github-app-auth.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/github-app-token-outputs" "${CASE_SHARED}/"

        cp -r "${TEMPLATE_DIR}" "${CASE_WORKDIR}"
        cd "${CASE_WORKDIR}"
        git fetch origin "${BASE_BRANCH}"
        git checkout "${BASE_BRANCH}"

        export SHARED_DIR="${CASE_SHARED}"
        export WORKDIR="${CASE_WORKDIR}"
        # Per-case ARTIFACT_DIR so resolver metadata (agent-model.json)
        # lands in the case artifacts instead of racing on the step dir.
        export ARTIFACT_DIR="${CASE_WORKDIR}/artifacts"
        export EVAL_MODE=true
        /opt/scripts/solve.sh

        # Copy small outputs to SHARED_DIR for judge/cleanup. Artifacts
        # stay on local disk — SHARED_DIR is a 3MiB kube secret.
        for f in claude-branch pr-number pr-description.md; do
            if [[ -f "${CASE_SHARED}/${f}" ]]; then
                cp "${CASE_SHARED}/${f}" "${REAL_SHARED_DIR}/${case_name}.${f}"
            fi
        done

        echo "pass" > "${RESULTS_DIR}/${case_name}"
    ) > "${ARTIFACT_DIR}/solve-${case_name}.log" 2>&1 &

    RUNNING=$(( RUNNING + 1 ))
    if [[ ${RUNNING} -ge ${MAX_PARALLEL} ]]; then
        wait -n || true
        RUNNING=$(( RUNNING - 1 ))
    fi
done

wait || true

# --- Report results ---
echo ""
echo "--- Solve Results ---"
FAILURES=0
for case_name in "${CASE_LIST[@]}"; do
    result=$(cat "${RESULTS_DIR}/${case_name}" 2>/dev/null || echo "fail")
    if [[ "${result}" == "pass" ]]; then
        echo "  [PASS] ${case_name}"
    else
        echo "  [FAIL] ${case_name} (see ${ARTIFACT_DIR}/solve-${case_name}.log)"
        FAILURES=$(( FAILURES + 1 ))
    fi
done

echo "Completed: ${#CASE_LIST[@]} cases, ${FAILURES} failures."

# Report which model actually ran (OpenCode does not export OTEL to the
# agentic-ci collector, so run-result is model-only, from the first case's
# resolver metadata).
if [[ ${#CASE_LIST[@]} -gt 0 && -f "/workspace/${CASE_LIST[0]}/artifacts/agent-model.json" ]]; then
    jq -n \
        --arg model "$(jq -r '.effective_model' "/workspace/${CASE_LIST[0]}/artifacts/agent-model.json")" \
        --arg agent "opencode" \
        --arg agent_version "${TRT_OPENCODE_VERSION}" \
        '{model: $model, agent: $agent, agent_version: $agent_version}' \
        > "${REAL_SHARED_DIR}/eval-solve-run-result.json"
    cp "${REAL_SHARED_DIR}/eval-solve-run-result.json" "${ARTIFACT_DIR}/eval-solve-run-result.json"
fi

# Always exit 0 so the judge step runs and produces the eval summary.
# The judge determines pass/fail based on check results.
echo "=== TRT Eval Solve Complete ==="
