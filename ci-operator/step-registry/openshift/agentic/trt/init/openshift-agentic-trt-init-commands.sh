#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Init ==="

# --- Gangway override ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY:-}" ]]; then
    echo "Applying Gangway override: JIRA_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
    JIRA_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
fi

[[ -n "${JIRA_ISSUE_KEY:-}" ]] || { echo "ERROR: JIRA_ISSUE_KEY is required."; exit 1; }
[[ -n "${UPSTREAM_REPO:-}" ]] || { echo "ERROR: UPSTREAM_REPO is required."; exit 1; }
[[ -n "${FORK_REPO:-}" ]] || { echo "ERROR: FORK_REPO is required."; exit 1; }

echo "Issue: ${JIRA_ISSUE_KEY} | Upstream: ${UPSTREAM_REPO} | Fork: ${FORK_REPO}"

# --- Validate GitHub tokens from github-app-auth step ---
for f in gh-fork-token gh-upstream-token; do
    [[ -f "${SHARED_DIR}/${f}" ]] || { echo "ERROR: ${f} not found in SHARED_DIR. Run trt-github-app-auth step first."; exit 1; }
done
echo "GitHub tokens validated."

# --- Persist issue key ---
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"

# --- Fetch Jira issue ---
echo "Fetching issue details from Jira..."
curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
    "https://redhat.atlassian.net/rest/api/2/issue/${JIRA_ISSUE_KEY}?fields=summary,description,status,labels,comment,issuetype,priority" \
    > "${SHARED_DIR}/jira-issue.json" || {
    echo "ERROR: Failed to fetch issue ${JIRA_ISSUE_KEY} from Jira."; exit 1;
}

echo "Summary: $(jq -r '.fields.summary // "No summary"' "${SHARED_DIR}/jira-issue.json")"

# --- Telemetry helper for downstream test steps ---
cat > "${SHARED_DIR}/trt-telemetry.sh" << 'HEREDOC_EOF'
#!/bin/bash
# TRT agentic telemetry helpers. Source from jira-solver / review-responder:
#   source "${SHARED_DIR}/trt-telemetry.sh"

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

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
    rm -f "${SHARED_DIR}/claude-otel.jsonl"
    if [[ ! -f "${EXTRACT_METRICS}" ]]; then
        echo "Warning: extract_metrics.py not found, skipping session metrics"
        return 0
    fi
    if [[ ! -s "${OTEL_LOG}" ]]; then
        echo "Warning: No OTEL data collected, skipping session metrics"
        return 0
    fi
    local metrics_tmp
    metrics_tmp=$(mktemp)
    if ! python3 "${EXTRACT_METRICS}" "${OTEL_LOG}" "${metrics_tmp}" 2>&1; then
        echo "Warning: Failed to extract session metrics"
        rm -f "${metrics_tmp}"
        return 0
    fi
    cp "${metrics_tmp}" "${SHARED_DIR}/claude-session-metrics-autodl.json"
    rm -f "${metrics_tmp}"
    echo "Session metrics autodl written to ${SHARED_DIR}/claude-session-metrics-autodl.json"
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/trt-telemetry.sh"
echo "Telemetry helper written to ${SHARED_DIR}/trt-telemetry.sh"

echo "=== TRT Init Complete ==="
