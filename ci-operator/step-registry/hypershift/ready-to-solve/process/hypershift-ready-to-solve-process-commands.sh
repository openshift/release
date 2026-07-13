#!/bin/bash
set -euo pipefail

echo "=== ASDLC Ready-to-Solve Validator ==="

# Apply Gangway API overrides
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY:-}" ]]; then
    echo "Applying Gangway override: JIRA_AGENT_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY}"
    export JIRA_AGENT_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY}"
fi

RESULTS_FILE="${SHARED_DIR}/ready-to-solve-results.txt"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
export CLAUDE_CONFIG_DIR

echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

# Force HTTPS for git operations (SSH lacks host keys in CI)
git config --global url."https://github.com/".insteadOf "git@github.com:"

echo "Installing Claude Code plugins..."
claude plugin marketplace add openshift-eng/ai-helpers
claude plugin install jira@ai-helpers

# Load Jira API credentials for Atlassian Cloud (Basic Auth: email:api-token)
JIRA_TOKEN_FILE="/var/run/claude-code-service-account/jira-pat"
JIRA_EMAIL_FILE="/var/run/claude-code-service-account/jira-email"
set +x
if [ -f "$JIRA_TOKEN_FILE" ] && [ -f "$JIRA_EMAIL_FILE" ]; then
    JIRA_TOKEN=$(cat "$JIRA_TOKEN_FILE")
    JIRA_EMAIL=$(cat "$JIRA_EMAIL_FILE")
    JIRA_AUTH=$(echo -n "${JIRA_EMAIL}:${JIRA_TOKEN}" | base64 | tr -d '\n')
    echo "Jira API credentials loaded"
else
    echo "ERROR: Jira credentials not found (need both jira-pat and jira-email)"
    exit 1
fi

WORKDIR=$(mktemp -d /tmp/ready-to-solve-XXXXXX)
cd "${WORKDIR}"
git init

copy_artifacts() {
    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}
trap copy_artifacts EXIT TERM INT

OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Skill"

agentic_ci() {
    local timeout_seconds=""
    if [[ "${1:-}" == "--timeout" ]]; then
        timeout_seconds="$2"; shift 2
    fi
    local prompt="$1"; shift
    local cmd=(
        agentic-ci run
        --backend local
        --harness claude-code
        --model "${CLAUDE_MODEL}"
        --workdir "${WORKDIR}"
        "${prompt}"
        --
        --permission-mode default
        --allowedTools "${ALLOWED_TOOLS}"
        --verbose
        "$@"
    )
    if [[ -n "${timeout_seconds}" ]]; then
        timeout "${timeout_seconds}" "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
    local rc=$?
    for f in /tmp/agentic-ci-run.*/claude-otel.jsonl; do
        [ -f "$f" ] && cat "$f" >> "${OTEL_LOG}"
    done
    rm -rf /tmp/agentic-ci-run.*
    return $rc
}

# Query Jira for issues deterministically via REST API
echo "Querying Jira for issues..."
if [[ -n "${JIRA_AGENT_ISSUE_KEY:-}" ]]; then
    if [[ ! "${JIRA_AGENT_ISSUE_KEY}" =~ ^[A-Z]+-[0-9]+$ ]]; then
        echo "ERROR: Invalid issue key format: ${JIRA_AGENT_ISSUE_KEY} (expected e.g. OCPBUGS-12345)"
        exit 1
    fi
    echo "Using override: JIRA_AGENT_ISSUE_KEY=${JIRA_AGENT_ISSUE_KEY}"
    JQL="key = ${JIRA_AGENT_ISSUE_KEY}"
else
    JQL='((project = OCPBUGS AND component = "Hypershift") OR project = CNTRLPLANE) AND resolution = Unresolved AND status in ("New", "To Do") AND labels = issue-for-agent ORDER BY created DESC'
fi

SEARCH_PAYLOAD=$(jq -n --arg jql "$JQL" --argjson max "${JIRA_AGENT_MAX_ISSUES}" \
    '{jql: $jql, fields: ["key", "summary", "components"], maxResults: $max}')
SEARCH_RESPONSE=$(curl -s -w "\n%{http_code}" "https://redhat.atlassian.net/rest/api/3/search/jql" \
    -X POST \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json" \
    -d "$SEARCH_PAYLOAD")
SEARCH_HTTP_CODE=$(echo "$SEARCH_RESPONSE" | tail -1)
SEARCH_BODY=$(echo "$SEARCH_RESPONSE" | sed '$d')

if [[ "$SEARCH_HTTP_CODE" != "200" ]]; then
    echo "ERROR: Jira search failed (HTTP $SEARCH_HTTP_CODE)"
    echo "Response: $SEARCH_BODY"
    exit 1
fi

TOTAL_RESULTS=$(echo "$SEARCH_BODY" | jq -r '.total // 0')
echo "Jira search returned $TOTAL_RESULTS result(s)"
ISSUES=$(echo "$SEARCH_BODY" | jq -r '.issues[]? | "\(.key) \([.fields.components[]?.name] | join(",")) \(.fields.summary)"')

if [[ -z "$ISSUES" ]]; then
    echo "No issues found matching criteria"
    exit 0
fi

echo "Found issues:"
while IFS= read -r line; do
    echo "  - $line"
done <<< "$ISSUES"

ISSUE_KEYS=()
while IFS= read -r line; do
    key=$(echo "$line" | awk '{print $1}')
    ISSUE_KEYS+=("$key")
done <<< "$ISSUES"

if [[ ${#ISSUE_KEYS[@]} -eq 0 ]]; then
    echo "No issues to validate. Exiting."
    exit 0
fi

echo ""
echo "=== Processing ${#ISSUE_KEYS[@]} issue(s) ==="

PROCESSED=0
PASSED=0
FAILED=0

for ISSUE_KEY in "${ISSUE_KEYS[@]}"; do
    PROCESSED=$((PROCESSED + 1))
    echo ""
    echo "--- [${PROCESSED}/${#ISSUE_KEYS[@]}] Validating ${ISSUE_KEY} ---"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    CLAUDE_EXIT=0
    agentic_ci --timeout 600 \
        "/jira:ready-to-solve ${ISSUE_KEY}" \
        --max-turns 50 \
        || CLAUDE_EXIT=$?

    # Check which label was applied by querying the issue
    LABEL="unknown"
    if [[ "${CLAUDE_EXIT}" -eq 0 ]] || [[ "${CLAUDE_EXIT}" -ne 124 ]]; then
        LABEL_RESPONSE=$(curl -s "https://redhat.atlassian.net/rest/api/3/issue/${ISSUE_KEY}?fields=labels" \
            -H "Authorization: Basic $JIRA_AUTH" \
            -H "Content-Type: application/json" 2>/dev/null) || true
        if echo "$LABEL_RESPONSE" | jq -e '.fields.labels[] | select(. == "ready-to-solve")' &>/dev/null; then
            LABEL="ready-to-solve"
        elif echo "$LABEL_RESPONSE" | jq -e '.fields.labels[] | select(. == "not-ready-to-solve")' &>/dev/null; then
            LABEL="not-ready-to-solve"
        fi
    fi

    if [[ "${CLAUDE_EXIT}" -eq 0 ]]; then
        echo "${ISSUE_KEY} ${TIMESTAMP} ${LABEL}" >> "${RESULTS_FILE}"
        PASSED=$((PASSED + 1))
    elif [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
        echo "Timed out validating ${ISSUE_KEY}"
        echo "${ISSUE_KEY} ${TIMESTAMP} TIMEOUT" >> "${RESULTS_FILE}"
        FAILED=$((FAILED + 1))
    else
        echo "Error validating ${ISSUE_KEY} (exit code: ${CLAUDE_EXIT})"
        echo "${ISSUE_KEY} ${TIMESTAMP} ERROR" >> "${RESULTS_FILE}"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=== Summary ==="
echo "Processed: ${PROCESSED}, Succeeded: ${PASSED}, Failed: ${FAILED}"

if [[ -f "${RESULTS_FILE}" ]]; then
    echo ""
    echo "ready-to-solve:"
    grep "ready-to-solve$" "${RESULTS_FILE}" | awk '{print "  - https://issues.redhat.com/browse/" $1}' || true
    echo ""
    echo "not-ready-to-solve:"
    grep "not-ready-to-solve$" "${RESULTS_FILE}" | awk '{print "  - https://issues.redhat.com/browse/" $1}' || true
    ERRORS=$(grep -E "TIMEOUT$|ERROR$" "${RESULTS_FILE}" || true)
    if [[ -n "$ERRORS" ]]; then
        echo ""
        echo "Errors/Timeouts:"
        echo "$ERRORS" | awk '{print "  - " $1 " (" $3 ")"}'
    fi
fi

echo ""
echo "=== Ready-to-Solve Validator Complete ==="
