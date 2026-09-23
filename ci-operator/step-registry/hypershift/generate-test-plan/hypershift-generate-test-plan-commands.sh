#!/bin/bash

set -euo pipefail

echo "=== HyperShift Generate Test Plan From PR ==="

if [[ "${GENERATE_TEST_PLAN_FROM_PR:-false}" != "true" ]]; then
  echo "GENERATE_TEST_PLAN_FROM_PR is not true — skipping."
  exit 0
fi

if [[ -f "${SHARED_DIR}/test-plan.yaml" ]]; then
  echo "SHARED_DIR/test-plan.yaml already exists — skipping LLM generation (explicit TEST_PLAN wins)."
  cp "${SHARED_DIR}/test-plan.yaml" "${ARTIFACT_DIR}/existing-test-plan.yaml" || true
  exit 0
fi

PR_NUMBER="${PULL_NUMBER:-}"
if [[ -z "${PR_NUMBER}" ]]; then
  echo "ERROR: PULL_NUMBER is not set — GENERATE_TEST_PLAN_FROM_PR requires a presubmit job."
  exit 1
fi

REPO_ORG="${REPO_OWNER:-openshift}"
REPO_NAME="${REPO_NAME:-hypershift}"
HYPERSHIFT_PLATFORM="${HYPERSHIFT_PLATFORM:-aws}"
OUTPUT_PLAN="/tmp/generated-test-plan.yaml"

echo "Generating test plan for PR #${PR_NUMBER} from ${REPO_ORG}/${REPO_NAME} (platform=${HYPERSHIFT_PLATFORM})"

# --- Claude session metrics (cost/tokens/timing) via agentic-ci + OTEL ---
EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

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

emit_session_metrics() {
  local stream_log="${1:-}"
  [ -s "${OTEL_LOG}" ] || { echo "No OTEL data collected; skipping session metrics"; return 0; }
  [ -f "${EXTRACT_METRICS}" ] || { echo "extract_metrics.py not found; skipping session metrics"; return 0; }
  local args=("${OTEL_LOG}" "${ARTIFACT_DIR}/claude-session-metrics-autodl.json")
  [ -n "${stream_log}" ] && [ -s "${stream_log}" ] && args+=(--stream-log "${stream_log}")
  python3 "${EXTRACT_METRICS}" "${args[@]}" || echo "Warning: session metrics extraction failed"
  return 0
}

if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found"
  exit 1
fi
echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"

# Clone the PR head so Claude can inspect the diff and source
echo "Cloning ${REPO_ORG}/${REPO_NAME} at PR head..."
git clone "https://github.com/${REPO_ORG}/${REPO_NAME}.git" /tmp/hypershift
cd /tmp/hypershift
git fetch origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
git checkout "pr-${PR_NUMBER}"

BASE_REF="${PULL_BASE_SHA:-}"
if [[ -n "${BASE_REF}" ]] && git cat-file -e "${BASE_REF}^{commit}" 2>/dev/null; then
  DIFF_RANGE="${BASE_REF}...HEAD"
else
  DIFF_RANGE="origin/${PULL_BASE_REF:-main}...HEAD"
fi

echo "Diff range: ${DIFF_RANGE}"
git diff --stat "${DIFF_RANGE}" > "${ARTIFACT_DIR}/pr-diff-stat.txt" || true
git diff --name-only "${DIFF_RANGE}" > "${ARTIFACT_DIR}/pr-changed-files.txt" || true

# Best-effort PR title/body for prompt context
PR_META_FILE="${ARTIFACT_DIR}/pr-metadata.json"
curl -sS "https://api.github.com/repos/${REPO_ORG}/${REPO_NAME}/pulls/${PR_NUMBER}" \
  > "${PR_META_FILE}" 2>/dev/null || echo '{}' > "${PR_META_FILE}"
PR_TITLE=$(jq -r '.title // empty' "${PR_META_FILE}" 2>/dev/null || true)
PR_BODY=$(jq -r '.body // empty' "${PR_META_FILE}" 2>/dev/null || true)

rm -f "${OUTPUT_PLAN}"

PROMPT="You are generating a HyperShift e2e-v2 TEST_PLAN YAML for CI.

CONTEXT:
- Repository: ${REPO_ORG}/${REPO_NAME}
- Pull request: #${PR_NUMBER}
- Platform: ${HYPERSHIFT_PLATFORM}
- Working directory: $(pwd) (checked out at the PR head)
- Diff range vs base: ${DIFF_RANGE}
- PR title: ${PR_TITLE:-"(unavailable)"}
- PR body (may be empty):
${PR_BODY:-"(unavailable)"}

GOAL:
Produce a focused TEST_PLAN that provisions the right guest cluster variant(s)
and selects Ginkgo tests whose labels match what this PR is likely to break.
Example: a change to the etcd StatefulSet should use a normal/default cluster
variant and a labelFilter that selects etcd-related tests.

HOW TO INVESTIGATE (use tools):
1. Inspect the PR diff (git diff ${DIFF_RANGE}) and changed files.
2. Find the e2e-v2 test plan schema, default plans, and available variants in
   this repo (search for TestPlan, test plan YAML, create-guests / run-tests,
   platform config, variants).
3. Find Ginkgo labels used by e2e tests (e.g. etcd, karpenter) that map to the
   changed areas.
4. Prefer the smallest useful plan: typically one parallel entry with an
   appropriate variant and labelFilter. Do not invent labels or variants that
   do not exist in the source.

OUTPUT CONTRACT (MANDATORY):
Write the final plan to exactly this path using the Write tool:
  ${OUTPUT_PLAN}

The file MUST be valid YAML (JSON is also fine) matching this shape:

name: <short-plan-id>
platform: ${HYPERSHIFT_PLATFORM}
testMatrix:
  parallel:
  - name: <group-name>
    variant: <variant-name>
    labelFilter: <ginkgo-label-filter>

Rules:
- Output ONLY the YAML/JSON plan content in that file (no markdown fences, no commentary).
- platform must be \"${HYPERSHIFT_PLATFORM}\".
- Use real variant and labelFilter values discovered in this repository.
- If the PR is too broad or you cannot map it to specific labels, choose a
  conservative default variant with a broad but valid labelFilter rather than
  inventing fields.
"

echo "Invoking Claude to generate test plan..."
set +e
run_claude_metered "${PROMPT}" "${ARTIFACT_DIR}/claude-generate-test-plan.json" \
  --allowedTools "Bash,Read,Write,Edit,Grep,Glob" \
  --max-turns 60
CLAUDE_EXIT=$?
set -e

emit_session_metrics "${ARTIFACT_DIR}/claude-generate-test-plan.json"

if [[ ${CLAUDE_EXIT} -ne 0 ]]; then
  echo "ERROR: Claude exited with code ${CLAUDE_EXIT}"
  exit 1
fi

if [[ ! -f "${OUTPUT_PLAN}" ]]; then
  echo "ERROR: Claude did not write ${OUTPUT_PLAN}"
  exit 1
fi

# Strip accidental markdown fences if present
python3 - "${OUTPUT_PLAN}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().strip()
fence = re.match(r"^```(?:ya?ml|json)?\s*\n(.*)\n```\s*$", text, re.DOTALL | re.IGNORECASE)
if fence:
    text = fence.group(1).strip()
open(path, "w", encoding="utf-8").write(text + "\n")
PY

# Validate minimal schema (prefer yq; fall back to PyYAML / JSON)
if command -v yq &>/dev/null; then
  NAME=$(yq -r '.name // ""' "${OUTPUT_PLAN}")
  PLAN_PLATFORM=$(yq -r '.platform // ""' "${OUTPUT_PLAN}")
  PARALLEL_LEN=$(yq -r '.testMatrix.parallel | length' "${OUTPUT_PLAN}")
  if [[ -z "${NAME}" || "${NAME}" == "null" ]]; then
    echo "ERROR: test plan missing required field: name"
    exit 1
  fi
  if [[ "${PLAN_PLATFORM}" != "${HYPERSHIFT_PLATFORM}" ]]; then
    echo "ERROR: platform must be '${HYPERSHIFT_PLATFORM}', got '${PLAN_PLATFORM}'"
    exit 1
  fi
  if [[ -z "${PARALLEL_LEN}" || "${PARALLEL_LEN}" == "null" || "${PARALLEL_LEN}" -lt 1 ]]; then
    echo "ERROR: testMatrix.parallel must be a non-empty list"
    exit 1
  fi
  for ((i=0; i<PARALLEL_LEN; i++)); do
    for key in name variant labelFilter; do
      val=$(yq -r ".testMatrix.parallel[${i}].${key} // \"\"" "${OUTPUT_PLAN}")
      if [[ -z "${val}" || "${val}" == "null" ]]; then
        echo "ERROR: parallel[${i}] missing required field: ${key}"
        exit 1
      fi
    done
  done
  echo "Test plan schema validation passed (yq)"
else
  python3 - "${OUTPUT_PLAN}" "${HYPERSHIFT_PLATFORM}" <<'PY'
import json
import sys

path, platform = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read()
try:
    import yaml
    data = yaml.safe_load(raw)
except Exception:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"ERROR: plan is not valid YAML/JSON: {e}", file=sys.stderr)
        sys.exit(1)

if not isinstance(data, dict):
    print("ERROR: test plan root must be a mapping", file=sys.stderr)
    sys.exit(1)
for key in ("name", "platform", "testMatrix"):
    if key not in data:
        print(f"ERROR: test plan missing required field: {key}", file=sys.stderr)
        sys.exit(1)
if data.get("platform") != platform:
    print(f"ERROR: platform must be {platform!r}, got {data.get('platform')!r}", file=sys.stderr)
    sys.exit(1)
matrix = data["testMatrix"]
if not isinstance(matrix, dict) or "parallel" not in matrix:
    print("ERROR: testMatrix.parallel is required", file=sys.stderr)
    sys.exit(1)
parallel = matrix["parallel"]
if not isinstance(parallel, list) or not parallel:
    print("ERROR: testMatrix.parallel must be a non-empty list", file=sys.stderr)
    sys.exit(1)
for i, entry in enumerate(parallel):
    if not isinstance(entry, dict):
        print(f"ERROR: parallel[{i}] must be a mapping", file=sys.stderr)
        sys.exit(1)
    for key in ("name", "variant", "labelFilter"):
        if not entry.get(key):
            print(f"ERROR: parallel[{i}] missing required field: {key}", file=sys.stderr)
            sys.exit(1)
print("Test plan schema validation passed")
PY
fi

cp "${OUTPUT_PLAN}" "${SHARED_DIR}/test-plan.yaml"
cp "${OUTPUT_PLAN}" "${ARTIFACT_DIR}/generated-test-plan.yaml"
echo "Wrote generated test plan to ${SHARED_DIR}/test-plan.yaml"
echo "--- generated-test-plan.yaml ---"
cat "${OUTPUT_PLAN}"
