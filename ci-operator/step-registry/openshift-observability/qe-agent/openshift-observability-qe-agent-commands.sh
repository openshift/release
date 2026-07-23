#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== OpenShift Observability QE Agent ==="

# ---------------------------------------------------------------------------
# 1. Verify the flat context file written by the test step is present.
#    SHARED_DIR only propagates flat files between steps — subdirectories
#    created in a test step are not visible in subsequent post steps.
# ---------------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/qe-agent-context.json" ]]; then
  echo "No ${SHARED_DIR}/qe-agent-context.json found — test steps may not have run or produced no results."
  echo "Skipping qe-agent."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Check whether the test step reported failures.
# ---------------------------------------------------------------------------
if ! grep -q '"has_test_failures": true' "${SHARED_DIR}/qe-agent-context.json" 2>/dev/null; then
  echo "All tests passed — no failures detected. Skipping qe-agent."
  exit 0
fi

echo "Test failures detected — proceeding with qe-agent analysis."

# ---------------------------------------------------------------------------
# 3. Verify Claude CLI is available
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping qe-agent."
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"

# ---------------------------------------------------------------------------
# 4. Validate and load the qe-agent skill by name.
#    Skills are hosted in the openshift/release step registry alongside this
#    step, under ci-operator/step-registry/openshift-observability/qe-agent/skills/.
#    Each team sets AGENT_SKILL to the name of their skill file (without .md).
# ---------------------------------------------------------------------------
if [[ -z "${AGENT_SKILL:-}" ]]; then
  echo "ERROR: AGENT_SKILL is not set — skipping qe-agent."
  exit 0
fi

# Reject names with path traversal or special characters — only allow
# alphanumeric, hyphens, and underscores.
if [[ ! "${AGENT_SKILL}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: AGENT_SKILL '${AGENT_SKILL}' contains invalid characters."
  echo "       Only alphanumeric characters, hyphens, and underscores are allowed."
  exit 0
fi

readonly SKILL_BASE_URL="https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/openshift-observability/qe-agent/skills"
readonly SKILL_URL="${SKILL_BASE_URL}/${AGENT_SKILL}.md"

echo "Fetching qe-agent skill '${AGENT_SKILL}' from ${SKILL_URL}..."

# --max-redirs 0: do not follow redirects — the allowlist check is on the
# constructed URL only, and a redirect could bypass it.
SKILL_CONTENT=$(curl -fsS --max-redirs 0 --connect-timeout 10 --max-time 30 --retry 3 "${SKILL_URL}") || true

if [[ -z "${SKILL_CONTENT}" ]]; then
  echo "ERROR: Failed to fetch skill '${AGENT_SKILL}' — check that the file exists at:"
  echo "       ci-operator/step-registry/openshift-observability/qe-agent/skills/${AGENT_SKILL}.md"
  exit 0
fi

# Guard against unexpectedly large payloads (100 KB limit).
# Use wc -c for a true byte count; ${#var} counts characters and would allow
# multi-byte UTF-8 content to bypass the limit.
readonly MAX_SKILL_BYTES=102400
SKILL_BYTE_COUNT=$(printf '%s' "${SKILL_CONTENT}" | wc -c)
if [[ ${SKILL_BYTE_COUNT} -gt ${MAX_SKILL_BYTES} ]]; then
  echo "ERROR: Skill content is ${SKILL_BYTE_COUNT} bytes, exceeds the ${MAX_SKILL_BYTES}-byte limit — skipping qe-agent."
  exit 0
fi

echo "Skill '${AGENT_SKILL}' loaded (${SKILL_BYTE_COUNT} bytes)."

# ---------------------------------------------------------------------------
# 5. Run Claude non-interactively with the skill as system prompt.
#
#    The full stream-json output is captured to a temp file so we can extract
#    cost/usage and a command audit log after Claude exits. The temp file is
#    NOT in ARTIFACT_DIR — it may contain cluster logs and API responses that
#    should not be uploaded to GCS. Only the derived extracts are saved there.
# ---------------------------------------------------------------------------
echo "Running qe-agent..."

_CLAUDE_TIMEOUT=$(( ${STEP_TIMEOUT_MINUTES:-90} - 10 ))
echo "Claude timeout: ${_CLAUDE_TIMEOUT}m (step timeout ${STEP_TIMEOUT_MINUTES:-90}m minus 10m for post-processing)"

_QE_STREAM=$(mktemp)
trap 'rm -f "${_QE_STREAM}"' EXIT

timeout "${_CLAUDE_TIMEOUT}m" claude --print \
  --dangerously-skip-permissions \
  --allowedTools "Bash,Read,Write,Grep,Glob" \
  --model "${CLAUDE_MODEL:-claude-opus-4-6}" \
  --max-budget-usd 5 \
  --verbose \
  --output-format stream-json \
  --system-prompt "${SKILL_CONTENT}" \
  "SHARED_DIR=${SHARED_DIR} ARTIFACT_DIR=${ARTIFACT_DIR}. The test step context is in ${SHARED_DIR}/qe-agent-context.json and JUnit XML files are at ${SHARED_DIR}/qe-agent-junit-*.xml. Execute the skill starting with Step 0: read ${SHARED_DIR}/qe-agent-context.json." \
  > "${_QE_STREAM}" 2>&1 \
  || true

# ---------------------------------------------------------------------------
# Cost tracking — the terminal "result" record contains token counts and USD
# cost but no cluster data, so saving it to ARTIFACT_DIR is safe.
# ---------------------------------------------------------------------------
grep '"type":"result"' "${_QE_STREAM}" 2>/dev/null | head -1 \
  > "${ARTIFACT_DIR}/qe-agent-usage.json" || true

if [[ -s "${ARTIFACT_DIR}/qe-agent-usage.json" ]]; then
  _COST=$(jq -r  '.total_cost_usd   // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  _TURNS=$(jq -r '.num_turns        // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  _DUR_S=$(( $(jq -r '.duration_ms  // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0) / 1000 ))
  _IN=$(jq -r    '.usage.input_tokens  // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  _OUT=$(jq -r   '.usage.output_tokens // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  printf 'Cost: $%s | Turns: %s | Duration: %ss | Tokens in: %s out: %s\n' \
    "${_COST}" "${_TURNS}" "${_DUR_S}" "${_IN}" "${_OUT}"
fi

# ---------------------------------------------------------------------------
# Tool call audit log — every tool invocation Claude made (command strings,
# file paths, search patterns). Cluster output (pod logs, events, API
# responses) is NOT captured here. Note: Bash command strings may reference
# sensitive paths (e.g. KUBECONFIG, mounted secrets) — treat this log with
# the same access controls as other CI artifacts.
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name == "Bash" or .name == "Read" or .name == "Write" or .name == "Grep" or .name == "Glob"))
    | "[" + .name + "] " + (if .name == "Bash" then (.input.command // "") elif .name == "Read" then (.input.file_path // "") elif .name == "Write" then (.input.file_path // "") elif .name == "Grep" then (.input.pattern // "") elif .name == "Glob" then (.input.pattern // "") else "" end)
  ' "${_QE_STREAM}" 2>/dev/null \
  > "${ARTIFACT_DIR}/qe-agent-commands.log" || true

  if [[ -s "${ARTIFACT_DIR}/qe-agent-commands.log" ]]; then
    _CMD_COUNT=$(grep -c '^\[' "${ARTIFACT_DIR}/qe-agent-commands.log" 2>/dev/null || echo 0)
    echo "Audit log: ${_CMD_COUNT} tool calls → ${ARTIFACT_DIR}/qe-agent-commands.log"
  fi
fi

# ---------------------------------------------------------------------------
# TR-01 / HU-01: Tag all AI-generated markdown output with a persistent
# banner. Uses find for recursive coverage of nested directories (e.g.
# test-fixes/). Skips files that already start with the banner to avoid
# duplication when the skill template also includes it. Guarded with
# || true to preserve best-effort exit semantics under errexit.
# ---------------------------------------------------------------------------
readonly _AI_BANNER='> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.'
while IFS= read -r md_file; do
  if head -1 "${md_file}" 2>/dev/null | grep -qF 'AI-Generated Content'; then
    continue
  fi
  _tmp=$(mktemp) || continue
  { printf '%s\n\n' "${_AI_BANNER}" | cat - "${md_file}" > "${_tmp}" && mv "${_tmp}" "${md_file}"; } \
    || { rm -f "${_tmp}" 2>/dev/null; true; }
done < <(find "${ARTIFACT_DIR}" -name '*.md' -type f 2>/dev/null || true)

# ---------------------------------------------------------------------------
# 6. File bug in Jira (opt-in via JIRA_PROJECT).
#    Runs AFTER Claude exits so credentials are never in the agent environment.
#    The skill writes jira-payload.json with pre-formatted wiki-notation content;
#    this section reads it and POSTs to Jira.
#    Tracing is disabled around credential handling to prevent leakage.
# ---------------------------------------------------------------------------
if [[ -n "${JIRA_PROJECT:-}" && -f "${ARTIFACT_DIR}/jira-payload.json" ]]; then
  echo "jira-payload.json found — attempting Jira filing for project ${JIRA_PROJECT}..."

  readonly _JIRA_CREDS_DIR="/var/run/claude-code-service-account"
  _jira_token_file="${_JIRA_CREDS_DIR}/jira-pat"
  _jira_email_file="${_JIRA_CREDS_DIR}/jira-email"

  if [[ -s "${_jira_token_file}" && -s "${_jira_email_file}" ]]; then
    [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
    set +x

    _jira_token=$(cat "${_jira_token_file}")
    _jira_email=$(cat "${_jira_email_file}")

    if [[ -z "${_jira_token}" || -z "${_jira_email}" ]]; then
      echo "WARNING: Jira credential files are empty — skipping Jira filing."
      $_was_tracing && set -x || true
    else
      _JIRA_AUTH=$(printf '%s:%s' "${_jira_email}" "${_jira_token}" | base64 | tr -d '\n')
      _JIRA_BASE_URL="${JIRA_BASE_URL:-https://redhat.atlassian.net}"
      _JIRA_ISSUE_TYPE="${JIRA_ISSUE_TYPE:-Bug}"

      # Validate JIRA_BASE_URL against allowlist
      case "${_JIRA_BASE_URL}" in
        https://redhat.atlassian.net|https://issues.redhat.com)
          ;;
        *)
          echo "WARNING: JIRA_BASE_URL '${_JIRA_BASE_URL}' is not an approved Jira host — skipping filing."
          _JIRA_AUTH=""
          $_was_tracing && set -x || true
          ;;
      esac

      if [[ -n "${_JIRA_AUTH}" ]]; then
        # Read pre-formatted fields from the skill-produced payload
        _JIRA_SUMMARY=$(jq -r '.summary // empty' "${ARTIFACT_DIR}/jira-payload.json")
        _JIRA_DESC=$(jq -r '.description // empty' "${ARTIFACT_DIR}/jira-payload.json")

        if [[ -z "${_JIRA_SUMMARY}" || -z "${_JIRA_DESC}" ]]; then
          echo "WARNING: jira-payload.json missing summary or description — skipping Jira filing."
          $_was_tracing && set -x || true
        else
          # Build the API payload with project and issue type
          _JIRA_PAYLOAD=$(mktemp)
          jq -n \
            --arg project "${JIRA_PROJECT}" \
            --arg summary "${_JIRA_SUMMARY}" \
            --arg issuetype "${_JIRA_ISSUE_TYPE}" \
            --arg desc "${_JIRA_DESC}" \
            '{
              fields: {
                project: {key: $project},
                summary: $summary,
                issuetype: {name: $issuetype},
                description: $desc
              }
            }' > "${_JIRA_PAYLOAD}"

          _JIRA_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
            --connect-timeout 10 --max-time 30 \
            "${_JIRA_BASE_URL}/rest/api/2/issue" \
            -H "Authorization: Basic ${_JIRA_AUTH}" \
            -H "Content-Type: application/json" \
            -d @"${_JIRA_PAYLOAD}") || true

          $_was_tracing && set -x || true

          _JIRA_HTTP=$(echo "${_JIRA_RESPONSE}" | tail -1)
          _JIRA_BODY=$(echo "${_JIRA_RESPONSE}" | sed '$d')

          if [[ "${_JIRA_HTTP}" == "201" ]]; then
            _JIRA_KEY=$(echo "${_JIRA_BODY}" | jq -r '.key // empty')
            if [[ -n "${_JIRA_KEY}" ]]; then
              echo "Jira issue created: ${_JIRA_KEY}"
              echo "${_JIRA_KEY}" >> "${ARTIFACT_DIR}/jira-issue-key.txt"

              if [[ -f "${ARTIFACT_DIR}/qe-agent-analysis.md" ]]; then
                printf '\n**Jira issue**: [%s](%s/browse/%s)\n' \
                  "${_JIRA_KEY}" "${_JIRA_BASE_URL}" "${_JIRA_KEY}" \
                  >> "${ARTIFACT_DIR}/qe-agent-analysis.md"
              fi

              # Set assignee if configured
              if [[ -n "${JIRA_ASSIGNEE:-}" ]]; then
                [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
                set +x

                _ASSIGNEE_RESP=$(curl -s -w "\n%{http_code}" -G \
                  --connect-timeout 10 --max-time 30 \
                  "${_JIRA_BASE_URL}/rest/api/2/user/assignable/search" \
                  -H "Authorization: Basic ${_JIRA_AUTH}" \
                  --data-urlencode "issueKey=${_JIRA_KEY}" \
                  --data-urlencode "query=${JIRA_ASSIGNEE}") || true

                $_was_tracing && set -x || true

                _ASSIGNEE_HTTP=$(echo "${_ASSIGNEE_RESP}" | tail -1)
                if [[ "${_ASSIGNEE_HTTP}" == "200" ]]; then
                  _ACCOUNT_ID=$(echo "${_ASSIGNEE_RESP}" | sed '$d' | jq -r '.[0].accountId // empty')
                  if [[ -n "${_ACCOUNT_ID}" ]]; then
                    [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
                    set +x

                    _ASSIGN_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                      --connect-timeout 10 --max-time 30 \
                      "${_JIRA_BASE_URL}/rest/api/2/issue/${_JIRA_KEY}/assignee" \
                      -H "Authorization: Basic ${_JIRA_AUTH}" \
                      -H "Content-Type: application/json" \
                      -d "{\"accountId\":\"${_ACCOUNT_ID}\"}") || true

                    $_was_tracing && set -x || true

                    if [[ "${_ASSIGN_HTTP}" == "204" ]]; then
                      echo "Assignee set to ${JIRA_ASSIGNEE}"
                    else
                      echo "WARNING: Failed to set assignee (HTTP ${_ASSIGN_HTTP})."
                    fi
                  else
                    echo "WARNING: No assignable account found for '${JIRA_ASSIGNEE}' — skipping assignee."
                  fi
                else
                  echo "WARNING: Jira assignable user search failed (HTTP ${_ASSIGNEE_HTTP}) — skipping assignee."
                fi
              fi
            fi
          else
            echo "WARNING: Jira issue creation failed (HTTP ${_JIRA_HTTP})."
          fi

          rm -f "${_JIRA_PAYLOAD}"
        fi
      fi
    fi

    unset _jira_token _jira_email _JIRA_AUTH
  else
    echo "WARNING: JIRA_PROJECT is set but jira-pat/jira-email not found or empty in ${_JIRA_CREDS_DIR}."
    echo "         Jira filing skipped. Add jira-pat and jira-email to the dt-secrets secret."
  fi
elif [[ -n "${JIRA_PROJECT:-}" ]]; then
  echo "JIRA_PROJECT is set but no jira-payload.json found — Jira filing skipped."
fi

echo "=== QE Agent Complete ==="

# Always exit 0 — best_effort post-step
exit 0
