#!/bin/bash
set -euo pipefail

echo "=== OADP Operator E2E Failure Analyzer ==="

# ---------------------------------------------------------------------------
# 1. Construct GCS base path and wait for test step artifacts
# ---------------------------------------------------------------------------
JOB_NAME="${JOB_NAME:-unknown}"
BUILD_ID="${BUILD_ID:-unknown}"
JOB_TYPE="${JOB_TYPE:-}"
PULL_NUMBER="${PULL_NUMBER:-}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"

if [[ "$JOB_TYPE" == "presubmit" ]] && [[ -n "$PULL_NUMBER" ]]; then
  GCS_BUCKET_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  GCS_BUCKET_PATH="logs/${JOB_NAME}/${BUILD_ID}"
fi

GCSWEB_BASE="https://gcs.ci.openshift.org/gcs/test-platform-results"
PROW_JOB_URL="${GCSWEB_BASE}/${GCS_BUCKET_PATH}"
ARTIFACTS_BASE="${GCSWEB_BASE}/${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}"

echo "Waiting for test step artifacts in GCS..."
FAILURE_DETECTED=false
FAILED_STEP=""
MAX_WAIT=600
POLL_INTERVAL=15
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
  for STEP_NAME in $TEST_STEPS; do
    FINISHED_JSON=$(curl -sL "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "$FINISHED_JSON" | jq -e '.passed == false' &>/dev/null; then
      echo "Detected test failure in ${STEP_NAME}/finished.json (waited ${WAITED}s)"
      FAILURE_DETECTED=true
      FAILED_STEP="$STEP_NAME"
      break 2
    elif echo "$FINISHED_JSON" | jq -e '.passed == true' &>/dev/null; then
      echo "Test step ${STEP_NAME} passed — skipping analysis."
      exit 0
    fi
  done

  echo "  Waiting for artifacts... (${WAITED}s/${MAX_WAIT}s)"
  sleep "$POLL_INTERVAL"
  WAITED=$((WAITED + POLL_INTERVAL))
done

if [[ "$FAILURE_DETECTED" == "false" ]]; then
  echo "Timed out waiting for test step artifacts after ${WAITED}s — skipping analysis."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Verify Claude Code CLI
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping analysis"
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"

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

# ---------------------------------------------------------------------------
# 2b. Redact sensitive information before it ever reaches CI logs/artifacts
# ---------------------------------------------------------------------------
# Claude has Bash/Read/WebFetch access and reads must-gather/pod logs that may
# themselves contain leaked credentials/tokens. Never stream its raw tool
# output to stdout (Prow's build-log.txt is public); only a redacted summary
# is ever printed or written to ARTIFACT_DIR.
redact_secrets() {
  sed -E \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-ACCESS-KEY]/g' \
    -e 's/(aws_secret_access_key[" :=]+)[A-Za-z0-9/+=]{40}/\1[REDACTED-AWS-SECRET]/g' \
    -e 's/"private_key": ?"-----BEGIN[^"]*END[^"]*"/"private_key": "[REDACTED-GCP-PRIVATE-KEY]"/g' \
    -e 's/Bearer +[A-Za-z0-9._~+-]+=*/Bearer [REDACTED-TOKEN]/g' \
    -e 's/(password[" :=]+)[^ "'"'"']+/\1[REDACTED-PASSWORD]/gi' \
    -e 's/(api[_-]?key[" :=]+)[^ "'"'"']+/\1[REDACTED-APIKEY]/gi' \
    -e 's/(token[" :=]+)[A-Za-z0-9._~+-]+=*/\1[REDACTED-TOKEN]/gi' \
    -e 's/(secret[" :=]+)[^ "'"'"']{16,}/\1[REDACTED-SECRET]/gi' \
    -e 's/eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/[REDACTED-JWT-TOKEN]/g' \
    -e 's/-----BEGIN (RSA |EC )?PRIVATE KEY-----[^-]*-----END (RSA |EC )?PRIVATE KEY-----/[REDACTED-PRIVATE-KEY]/g'
}

# ---------------------------------------------------------------------------
# 3. Run Claude with the pre-installed ai-helpers skill
# ---------------------------------------------------------------------------
echo "Analyzing failed step: $FAILED_STEP"

SYSTEM_PROMPT="IMPORTANT CI CONTEXT:
- You are running inside the CI job itself as a post-step.
- This step's artifact directory is: ${ARTIFACT_DIR}
- Other steps' artifacts (build-log, JUnit, must-gather, per-test pod logs) are available via GCS at: ${PROW_JOB_URL}
- You have network access to download artifacts from GCS using curl.
- Write the final analysis report to: ${ARTIFACT_DIR}/failure-analysis.md
- Use --fast mode (do NOT use AskUserQuestion).
- Do NOT prompt for JIRA export — just write the markdown analysis.

OADP CONTEXT:
- OADP (OpenShift API for Data Protection) is an operator that installs and manages Velero for backup/restore in OpenShift.
- Core resources: DataProtectionApplication (DPA), BackupStorageLocation (BSL), VolumeSnapshotLocation (VSL), CloudStorage, DataProtectionTest, NonAdminBackup/NonAdminRestore.
- E2E tests use Ginkgo v2, filtered by cloud provider/feature labels: aws, gcp, azure, ibmcloud, virt, hcp, cli, upgrade.
- Artifacts of interest per test:
  - junit_report.xml: structured pass/fail results.
  - must-gather/clusters/<cluster-id>/oadp-must-gather-summary.md: high-level cluster diagnostics summary.
  - must-gather/clusters/<cluster-id>/namespaces/openshift-adp/: Velero/node-agent/plugin pod logs, DPA/BSL/VSL/backup/restore resources.
  - Per-test directories with pod logs from the openshift-adp namespace and application namespaces under test.

SOURCE CODE ACCESS (this pod runs on a generic image — the oadp-operator repo is NOT pre-checked-out, unlike the old in-container analysis this replaces):
- You have git, gh, and general network access in this environment. If artifact-based evidence alone isn't enough to explain a failure, clone the source yourself:
    git clone --depth 1 --branch ${OADP_BRANCH} https://github.com/openshift/oadp-operator /tmp/oadp-operator
    git clone --depth 1 --branch ${OADP_BRANCH} https://github.com/openshift/velero /tmp/velero
  (branch names are mirrored 1:1 between the two repos — confirmed via https://github.com/oadp-rebasebot/oadp-rebase/blob/oadp-dev/repos.yaml, the canonical source of truth for OADP ecosystem repo/branch mappings.)
- Known flakes are tracked in /tmp/oadp-operator/tests/e2e/lib/flakes.go (flakePatterns / errorIgnorePatterns) — cross-reference failure signatures against known issue patterns before treating them as new bugs.
- OADP is a thin operator wrapping Velero: most real backup/restore root causes live in Velero's own controller code (/tmp/velero/pkg/controller/), not OADP's wrapper. Grep there for error strings you find in pod logs before concluding something is an OADP-specific bug.
- If evidence instead points into a cloud-provider plugin or other OADP ecosystem component (e.g. an AWS-specific snapshot error suggesting velero-plugin-for-aws, a KubeVirt VM backup error suggesting kubevirt-velero-plugin, or a HyperShift-specific failure suggesting hypershift-oadp-plugin) rather than core Velero or oadp-operator itself, don't guess the repo/org/branch — fetch https://raw.githubusercontent.com/oadp-rebasebot/oadp-rebase/oadp-dev/repos.yaml (WebFetch or curl) and look up that component's entry: use its \`org\`/\`repo\` for the clone URL, and clone the branch named in its \`dev_branch\` field if present, otherwise ${OADP_BRANCH} (a few repos, e.g. kubevirt-velero-plugin and hypershift-oadp-plugin, only develop on \`main\` and don't mirror OADP's oadp-1.x/oadp-dev branch scheme at all — that's exactly what \`dev_branch\` overrides for). If the branch you pick 404s, retry with \`main\` as a last resort."

echo ""
echo "Running Claude with /ci:prow-job-analysis skill..."
echo ""

set +e
CLAUDE_TIMEOUT=1200 run_claude_metered "/ci:prow-job-analysis ${PROW_JOB_URL} --fast" \
  "${ARTIFACT_DIR}/claude-failure-analysis.json" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch Skill" \
  --max-turns 100
CLAUDE_EXIT=$?
set -e

# Best-effort: emit claude-session-metrics-autodl.json from collected OTEL.
emit_session_metrics "${ARTIFACT_DIR}/claude-failure-analysis.json"

if [[ "$CLAUDE_EXIT" -eq 124 ]]; then
  echo "Claude timed out — report may be incomplete"
fi

# ---------------------------------------------------------------------------
# 4. Extract token usage
# ---------------------------------------------------------------------------

TOKENS_JSON=$(grep '"type":"result"' "${ARTIFACT_DIR}/claude-failure-analysis.json" 2>/dev/null \
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

DURATION_MS=$(echo "$TOKENS_JSON" | jq -r '.duration_ms // 0')
DURATION_S=$(printf '%.0f' "$(echo "${DURATION_MS} / 1000" | bc -l 2>/dev/null)" 2>/dev/null || echo 0)
NUM_TURNS=$(echo "$TOKENS_JSON" | jq -r '.num_turns // 0')

jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' \
  "${ARTIFACT_DIR}/claude-failure-analysis.json" \
  | redact_secrets \
  > "${ARTIFACT_DIR}/claude-failure-analysis-text.txt" 2>/dev/null || true

echo "$TOKENS_JSON" > "${SHARED_DIR}/claude-failure-analysis-tokens.json" 2>/dev/null || true

# Redact the report Claude wrote directly, and the raw stream-json transcript
# (which can contain full tool-call inputs/outputs from artifacts it read),
# in place before either is left in ARTIFACT_DIR for GCS upload.
for f in "${ARTIFACT_DIR}/failure-analysis.md" "${ARTIFACT_DIR}/claude-failure-analysis.json" "${ARTIFACT_DIR}/claude-failure-analysis.log"; do
  if [[ -f "$f" ]]; then
    redact_secrets < "$f" > "${f}.redacted" 2>/dev/null && mv "${f}.redacted" "$f"
  fi
done

echo ""
echo "=== Failure Analysis Complete ==="
echo "Claude exit code: $CLAUDE_EXIT"
echo "Duration: ${DURATION_S}s"
echo "Turns: ${NUM_TURNS}"
echo "Analysis (redacted): ${ARTIFACT_DIR}/failure-analysis.md"

exit 0
