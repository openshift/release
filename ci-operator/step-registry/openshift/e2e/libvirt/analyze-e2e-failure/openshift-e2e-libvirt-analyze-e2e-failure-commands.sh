#!/bin/bash
set -euo pipefail

if [[ "${LIBVIRT_E2E_FAILURE_ANALYSIS_ENABLED:-false}" != "true" ]]; then
  echo "Libvirt E2E failure analysis disabled (set LIBVIRT_E2E_FAILURE_ANALYSIS_ENABLED=true to enable)."
  exit 0
fi

echo "=== Libvirt E2E Failure Analyzer ==="

JOB_NAME="${JOB_NAME:-unknown}"
BUILD_ID="${BUILD_ID:-unknown}"
JOB_TYPE="${JOB_TYPE:-}"
PULL_NUMBER="${PULL_NUMBER:-}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"
GCS_HTTPS="https://storage.googleapis.com/test-platform-results"
MAX_ARTIFACT_BYTES=8388608

if [[ -z "${TEST_NAME:-}" ]]; then
  if [[ "${JOB_NAME}" =~ (ocp-[^/]+)$ ]]; then
    TEST_NAME="${BASH_REMATCH[1]}"
  elif [[ "${JOB_NAME}" =~ (e2e-[^/]+)$ ]]; then
    TEST_NAME="${BASH_REMATCH[1]}"
  else
    echo "ERROR: TEST_NAME is empty and could not be derived from JOB_NAME=${JOB_NAME} — skipping analysis."
    exit 0
  fi
fi

if [[ "${JOB_TYPE}" == "presubmit" && -n "${PULL_NUMBER}" ]]; then
  GCS_BUCKET_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  GCS_BUCKET_PATH="logs/${JOB_NAME}/${BUILD_ID}"
fi

GCSWEB_BASE="https://gcs.ci.openshift.org/gcs/test-platform-results"
PROW_JOB_URL="${GCSWEB_BASE}/${GCS_BUCKET_PATH}"
ARTIFACTS_BASE="${GCSWEB_BASE}/${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}"

echo "Waiting for test step artifacts in GCS (TEST_NAME=${TEST_NAME} ARCH=${ARCH:-unset})..."
FAILURE_DETECTED=false
FAILED_STEP=""
MAX_WAIT=600
POLL_INTERVAL=15
START_TIME=${SECONDS}

while (( (SECONDS - START_TIME) < MAX_WAIT )); do
  for STEP_NAME in ${TEST_STEPS}; do
    FINISHED_JSON=$(curl -sL --connect-timeout 10 --max-time 20 \
      "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "${FINISHED_JSON}" | jq -e '.passed == false' &>/dev/null; then
      echo "Detected failure in ${STEP_NAME}/finished.json (elapsed $((SECONDS - START_TIME))s)"
      FAILURE_DETECTED=true
      FAILED_STEP="${STEP_NAME}"
      break 2
    fi
  done

  all_passed=true
  saw_any=false
  for STEP_NAME in ${TEST_STEPS}; do
    FINISHED_JSON=$(curl -sL --connect-timeout 10 --max-time 20 \
      "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "${FINISHED_JSON}" | jq -e '.passed == true' &>/dev/null; then
      saw_any=true
      continue
    fi
    all_passed=false
    break
  done
  if [[ "${saw_any}" == "true" && "${all_passed}" == "true" ]]; then
    echo "Listed test steps passed — skipping analysis."
    exit 0
  fi

  echo "  Waiting for artifacts... ($((SECONDS - START_TIME))s/${MAX_WAIT}s)"
  sleep "${POLL_INTERVAL}"
done

if [[ "${FAILURE_DETECTED}" == "false" ]]; then
  echo "Timed out waiting for failed-step artifacts after $((SECONDS - START_TIME))s — skipping analysis."
  exit 0
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping analysis"
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"
echo "Failed step: ${FAILED_STEP}"

WORK_DIR=$(mktemp -d /tmp/libvirt-e2e-analysis.XXXXXX)
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# Wrapper-owned fetches only. Claude is not given Bash/WebFetch, so it cannot
# read the Vertex SA key or exfiltrate it from untrusted artifacts.
fetch_gcs() {
  local object_name="$1"
  local dest="$2"
  shift 2
  mkdir -p "$(dirname "${dest}")"
  local code
  code=$(curl -sL --connect-timeout 10 --max-time 60 "$@" \
    -w '%{http_code}' -o "${dest}.tmp" "${GCS_HTTPS}/${object_name}" || echo "000")
  if [[ "${code}" == "200" || "${code}" == "206" ]]; then
    mv "${dest}.tmp" "${dest}"
    echo "  fetched ${object_name} (${code})"
    return 0
  fi
  rm -f "${dest}.tmp"
  return 1
}

local_from_bucket() {
  local object_name="$1"
  echo "${WORK_DIR}/${object_name#${GCS_BUCKET_PATH}/}"
}

echo "Downloading a bounded artifact set for local analysis..."
fetch_gcs "${GCS_BUCKET_PATH}/prowjob.json" "$(local_from_bucket "${GCS_BUCKET_PATH}/prowjob.json")" || true
fetch_gcs "${GCS_BUCKET_PATH}/build-log.txt" "$(local_from_bucket "${GCS_BUCKET_PATH}/build-log.txt")" \
  -H "Range: bytes=-2097152" || true
fetch_gcs "${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}/${FAILED_STEP}/finished.json" \
  "$(local_from_bucket "${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}/${FAILED_STEP}/finished.json")" || true
fetch_gcs "${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}/${FAILED_STEP}/build-log.txt" \
  "$(local_from_bucket "${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}/${FAILED_STEP}/build-log.txt")" \
  -H "Range: bytes=-2097152" || true

fetch_junit_prefix() {
  local prefix="$1"
  local encoded resp name dest
  encoded=$(jq -nr --arg p "${prefix}" '$p|@uri')
  resp=$(curl -sL --connect-timeout 10 --max-time 30 \
    "https://storage.googleapis.com/storage/v1/b/test-platform-results/o?prefix=${encoded}&maxResults=50&fields=items(name,size)" \
    || true)
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    dest=$(local_from_bucket "${name}")
    fetch_gcs "${name}" "${dest}" || true
  done < <(echo "${resp}" | jq -r --argjson max "${MAX_ARTIFACT_BYTES}" '
    .items[]?
    | select((.size | tonumber) < $max)
    | select(.name | test("junit.*\\.xml$|\\.xml$"))
    | .name
  ' | head -n 20 || true)
}

fetch_junit_prefix "${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}/${FAILED_STEP}/artifacts/junit"
fetch_junit_prefix "${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}/${FAILED_STEP}/artifacts/"

if [[ -z "$(find "${WORK_DIR}" -type f -print -quit 2>/dev/null)" ]]; then
  echo "ERROR: no artifacts downloaded — skipping analysis."
  exit 0
fi

# Runtime CI context is always prepended. SYSTEM_PROMPT is the platform-specific
# override (libvirt by default; PowerVC and others can set it on the step).
CI_CONTEXT="IMPORTANT CI CONTEXT:
- You are running inside the CI job itself as a post-step.
- Analyze ONLY the local files under: ${WORK_DIR}
- Write the final analysis report to: ${ARTIFACT_DIR}/failure-analysis.md
- Use --fast mode (do NOT use AskUserQuestion).
- Do NOT prompt for JIRA export — just write the markdown analysis.
- Do NOT fetch URLs or use network tools.
- NEVER read files under /var/run/
- NEVER access credential or token files
- Failed step: ${FAILED_STEP}
- ARCH is ${ARCH:-unknown}.
- Prow job URL (reference only, do not fetch): ${PROW_JOB_URL}"

FULL_PROMPT="${CI_CONTEXT}

${SYSTEM_PROMPT:-}"

echo ""
echo "Running Claude against local artifacts (no Bash/WebFetch)..."
echo ""

CLAUDE_JSON="${ARTIFACT_DIR}/claude-output.json"

# --- Claude session metrics (cost/tokens/timing) via agentic-ci + OTEL ---
# extract_metrics.py ships in the claude-ai-helpers image and produces the
# claude_session_metrics BigQuery autodl consumed by the CI cost dashboards.
EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

# run_claude_metered <prompt> <stream_json_out> [extra claude args...]
# Runs Claude through `agentic-ci run` so an ephemeral OTEL collector captures
# cost/token/timing telemetry. Writes raw stream-json to <stream_json_out>
# (agentic-ci log lines stripped) and appends per-run OTEL to ${OTEL_LOG}.
# Honors ${CLAUDE_TIMEOUT} (a `timeout`-style duration, e.g. 1200 or 35m) when set.
# Returns the claude/agentic-ci exit code.
run_claude_metered() {
  local prompt="$1"; shift
  local out_file="$1"; shift
  local raw rc=0 timeout_cmd=()
  raw="$(mktemp)"
  [ -n "${CLAUDE_TIMEOUT:-}" ] && timeout_cmd=(timeout "${CLAUDE_TIMEOUT}")
  "${timeout_cmd[@]}" agentic-ci run \
    --backend local \
    --harness claude-code \
    --model "${CLAUDE_MODEL}" \
    --workdir "${PWD}" \
    --no-streaming \
    "${prompt}" \
    -- \
    --verbose \
    --output-format stream-json \
    "$@" \
    > "${raw}" 2>>"${ARTIFACT_DIR}/claude-agentic-ci.log" || rc=$?
  grep '^{' "${raw}" > "${out_file}" || true
  rm -f "${raw}"
  local f
  for f in /tmp/agentic-ci-run.*/claude-otel.jsonl; do
    [ -f "$f" ] && cat "$f" >> "${OTEL_LOG}"
  done
  rm -rf /tmp/agentic-ci-run.* 2>/dev/null || true
  return $rc
}

# emit_session_metrics [stream_json_out]
# Best-effort: emit ${ARTIFACT_DIR}/claude-session-metrics-autodl.json from the
# collected OTEL, enriched with identity fields from the stream-json when given.
emit_session_metrics() {
  local stream_log="${1:-}"
  [ -s "${OTEL_LOG}" ] || { echo "No OTEL data collected; skipping session metrics"; return 0; }
  [ -f "${EXTRACT_METRICS}" ] || { echo "extract_metrics.py not found; skipping session metrics"; return 0; }
  local args=("${OTEL_LOG}" "${ARTIFACT_DIR}/claude-session-metrics-autodl.json")
  [ -n "${stream_log}" ] && [ -s "${stream_log}" ] && args+=(--stream-log "${stream_log}")
  python3 "${EXTRACT_METRICS}" "${args[@]}" || echo "Warning: session metrics extraction failed"
  return 0
}

# Vertex auth stays mounted for the Claude CLI process. Agent tools cannot
# reach it: Bash/WebFetch are denied and Read is blocked under /var/run/.
set +e
CLAUDE_TIMEOUT=1200 run_claude_metered \
  "Analyze the failed OpenShift CI e2e job using only the local artifacts in ${WORK_DIR}. Write ${ARTIFACT_DIR}/failure-analysis.md." \
  "${CLAUDE_JSON}" \
  --append-system-prompt "${FULL_PROMPT}" \
  --allowedTools "Read Write Edit Grep Glob" \
  --disallowedTools "Bash WebFetch Skill Read(/var/run/**) Read(/var/run/claude-code-service-account/**)" \
  --max-turns 100
CLAUDE_EXIT=$?
set -e

emit_session_metrics "${CLAUDE_JSON}"

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
  echo "Claude timed out — report may be incomplete"
fi

TOKENS_JSON=$(grep '"type":"result"' "${CLAUDE_JSON}" 2>/dev/null \
  | head -1 \
  | jq '{
      total_cost_usd: (.total_cost_usd // 0),
      duration_ms: (.duration_ms // 0),
      num_turns: (.num_turns // 0),
      input_tokens: (.usage.input_tokens // 0),
      output_tokens: (.usage.output_tokens // 0),
      cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
      cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0)
    }' 2>/dev/null \
  || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}')

echo "${TOKENS_JSON}" > "${SHARED_DIR}/claude-failure-analysis-tokens.json" 2>/dev/null || true
echo "${TOKENS_JSON}" > "${ARTIFACT_DIR}/claude-usage.json"

if [[ -f "${ARTIFACT_DIR}/failure-analysis.md" ]]; then
  sed -E \
    -e 's/ya29\.[A-Za-z0-9._-]+/[REDACTED]/g' \
    -e 's/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/[REDACTED]/g' \
    -e 's/-----END [A-Z0-9 ]*PRIVATE KEY-----/[REDACTED]/g' \
    -e 's/AIza[0-9A-Za-z_-]{20,}/[REDACTED]/g' \
    "${ARTIFACT_DIR}/failure-analysis.md" > "${ARTIFACT_DIR}/failure-analysis.md.redacted"
  mv "${ARTIFACT_DIR}/failure-analysis.md.redacted" "${ARTIFACT_DIR}/failure-analysis.md"
fi

echo ""
echo "=== Failure Analysis Complete ==="
echo "Claude exit code: ${CLAUDE_EXIT}"
echo "Analysis: ${ARTIFACT_DIR}/failure-analysis.md"

exit 0
