#!/bin/bash
set -euo pipefail

function require_html_sanitizer() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is missing from the CI image; cannot sanitize HTML" >&2
    exit 1
  fi

  if ! python3 -c 'import bleach' >/dev/null 2>&1; then
    echo "ERROR: Python module bleach is missing from the CI image; refusing to publish HTML" >&2
    exit 1
  fi
}

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

require_html_sanitizer

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
- Write the final analysis report to: ${ARTIFACT_DIR}/failure-analysis.html
- Use --fast mode (do NOT use AskUserQuestion).
- Do NOT prompt for JIRA export — just write the HTML analysis.
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

CLAUDE_JSON="${WORK_DIR}/claude-failure-analysis.json"
CLAUDE_LOG="${WORK_DIR}/claude-failure-analysis.log"

# Vertex auth stays mounted for the Claude CLI process. Agent tools cannot
# reach it: Bash/WebFetch are denied and Read is blocked under /var/run/.
set +e
timeout 1200 claude -p "Analyze the failed OpenShift CI e2e job using only the local artifacts in ${WORK_DIR}. Write ${ARTIFACT_DIR}/failure-analysis.html." \
  --append-system-prompt "${FULL_PROMPT}" \
  --allowedTools "Read Write Edit Grep Glob" \
  --disallowedTools "Bash WebFetch Skill Read(/var/run/**) Read(/var/run/claude-code-service-account/**)" \
  --max-turns 100 \
  --model "${CLAUDE_MODEL}" \
  --verbose \
  --output-format stream-json \
  > "${CLAUDE_JSON}" \
  2> "${CLAUDE_LOG}"
CLAUDE_EXIT=$?
set -e

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

function redact_secrets() {
  awk '
    /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/ {
      print "[REDACTED-PRIVATE-KEY]"
      in_pem=1
      next
    }
    in_pem {
      if (/-----END [A-Z0-9 ]*PRIVATE KEY-----/) in_pem=0
      next
    }
    { print }
  ' |
  sed -E \
    -e 's/ya29\.[A-Za-z0-9._-]+/[REDACTED-GCP-TOKEN]/g' \
    -e 's/AIza[0-9A-Za-z_-]{20,}/[REDACTED-GCP-API-KEY]/g' \
    -e 's/(AKIA|ASIA)[0-9A-Z]{16}/[REDACTED-AWS-ACCESS-KEY]/g' \
    -e 's/(aws_secret_access_key[":= ]+)[A-Za-z0-9\/+=]{40}/\1[REDACTED-AWS-SECRET]/gi' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED-TOKEN]/g' \
    -e 's/(github_pat_|gh[pousr]_)[A-Za-z0-9_]+/[REDACTED-GITHUB-TOKEN]/g' \
    -e 's/eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/[REDACTED-JWT-TOKEN]/g' \
    -e "s/(password[\":= ]+)[^ \"']+/\\1[REDACTED-PASSWORD]/gi" \
    -e "s/(api[_-]?key[\":= ]+)[^ \"']+/\\1[REDACTED-API-KEY]/gi" \
    -e "s/(token[\":= ]+)[A-Za-z0-9._~+\/-]+=*/\\1[REDACTED-TOKEN]/gi"
}

function sanitize_html() {
  python3 - "$1" "$2" <<'PY'
import sys
import bleach

src, dst = sys.argv[1:]
allowed_tags = {
    "html", "head", "body", "meta", "title",
    "h1", "h2", "h3", "p", "ul", "ol", "li",
    "table", "thead", "tbody", "tfoot", "tr", "th", "td",
    "pre", "code", "strong", "em", "br", "hr", "a",
}
allowed_attributes = {
    "a": ["href", "title"],
    "th": ["colspan", "rowspan"],
    "td": ["colspan", "rowspan"],
}

with open(src, encoding="utf-8") as stream:
    html = stream.read()

clean = bleach.clean(
    html,
    tags=allowed_tags,
    attributes=allowed_attributes,
    protocols=["http", "https"],
    strip=True,
    strip_comments=True,
)

with open(dst, "w", encoding="utf-8") as stream:
    stream.write(clean)
PY
}

ANALYSIS_POSTPROCESS_FAILED=false
REPORT="${ARTIFACT_DIR}/failure-analysis.html"

if [[ -f "${REPORT}" ]]; then
  REDACTED="${REPORT}.redacted"
  SANITIZED="${REPORT}.sanitized"

  if ! redact_secrets < "${REPORT}" > "${REDACTED}"; then
    echo "ERROR: secret redaction failed; removing report" >&2
    rm -f "${REPORT}" "${REDACTED}" "${SANITIZED}"
    ANALYSIS_POSTPROCESS_FAILED=true
  elif ! sanitize_html "${REDACTED}" "${SANITIZED}"; then
    echo "ERROR: HTML sanitization failed; removing report" >&2
    rm -f "${REPORT}" "${REDACTED}" "${SANITIZED}"
    ANALYSIS_POSTPROCESS_FAILED=true
  else
    mv "${SANITIZED}" "${REPORT}"
    rm -f "${REDACTED}"
  fi
fi

if [[ "${ANALYSIS_POSTPROCESS_FAILED}" == "true" ]]; then
  echo "=== Failure Analysis Failed ===" >&2
  exit 1
fi

echo ""
echo "Claude exit code: ${CLAUDE_EXIT}"

if [[ "${CLAUDE_EXIT}" -ne 0 ]]; then
  echo "ERROR: Claude analysis failed with exit code ${CLAUDE_EXIT}" >&2
  if [[ -s "${CLAUDE_LOG}" ]]; then
    echo "Claude log: ${CLAUDE_LOG}" >&2
  fi
fi

# Never print a success message or a deleted artifact path.
if [[ ! -f "${REPORT}" ]]; then
  echo "=== Failure Analysis Failed ===" >&2
  exit 1
fi

echo ""
echo "Claude exit code: ${CLAUDE_EXIT}"
if [[ "${CLAUDE_EXIT}" -eq 0 ]]; then
  echo "=== Failure Analysis Complete ==="
else
  echo "=== Failure Analysis Incomplete ===" >&2
fi
echo "Analysis: ${REPORT}"

exit 0
