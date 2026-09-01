#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Init ==="

SEED_TOKEN_FILE="/var/run/github-reviewer-token/token"
if [[ ! -f "${SEED_TOKEN_FILE}" ]]; then
    echo "ERROR: ${SEED_TOKEN_FILE} not found — mount trt-agentic-eval-gh-token"
    exit 1
fi

# Disable tracing while loading secrets
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
GITHUB_SEED_TOKEN=$(cat "${SEED_TOKEN_FILE}")
export GITHUB_SEED_TOKEN

EVAL_CONFIG="${EVAL_CONFIG:-/opt/ai-helpers/evals/review-responder/review-responder-eval.yaml}"

CASE_ARGS=()
if [[ -n "${EVAL_CASE:-}" ]]; then
    CASE_ARGS+=("--case=${EVAL_CASE}")
fi

prow-agent-eval init \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --mode=followup \
    "${CASE_ARGS[@]+"${CASE_ARGS[@]}"}"

# --- Telemetry helper for downstream test steps ---
cat > "${SHARED_DIR}/trt-telemetry.sh" << 'HEREDOC_EOF'
#!/bin/bash
# TRT agentic telemetry helpers. Source from jira-solver / review-responder:
#   source "${SHARED_DIR}/trt-telemetry.sh"

OTEL_LOG="${SHARED_DIR}/claude-otel.jsonl"

agentic_ci() {
    local timeout_seconds=""
    local extra_args=()
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --timeout) timeout_seconds="$2"; shift 2 ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done
    local prompt="$1"; shift
    local cmd=(
        agentic-ci run
        --backend local
        --harness claude-code
        --model "${CLAUDE_MODEL}"
        --workdir "${WORKDIR}"
        "${extra_args[@]+"${extra_args[@]}"}"
        "${prompt}"
        --
        --permission-mode default
        --allowedTools "${ALLOWED_TOOLS}"
        --verbose
        "$@"
    )
    local run_tmp
    run_tmp=$(mktemp -d /tmp/agentic-ci-wrapper.XXXXXX)
    local rc=0
    if [[ -n "${timeout_seconds}" ]]; then
        TMPDIR="${run_tmp}" timeout "${timeout_seconds}" "${cmd[@]}" 2>&1 | tee -a "${WORKDIR}/artifacts/claude-output.log" || rc=${PIPESTATUS[0]}
    else
        TMPDIR="${run_tmp}" "${cmd[@]}" 2>&1 | tee -a "${WORKDIR}/artifacts/claude-output.log" || rc=${PIPESTATUS[0]}
    fi
    find "${run_tmp}" -name 'claude-otel.jsonl' -type f -exec cat {} + >> "${OTEL_LOG}" 2>/dev/null || true
    rm -rf "${run_tmp}"
    return $rc
}

finalize_session_metrics() {
    return 0
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/trt-telemetry.sh"
echo "Telemetry helper written to ${SHARED_DIR}/trt-telemetry.sh"

echo "=== TRT Review Responder Eval Init Complete ==="
