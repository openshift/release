#!/bin/bash
#
# Intelliaide Prow CI credential proof-of-concept.
#
# Phase 1: Intelliaide-style auth (google-auth ADC via GOOGLE_APPLICATION_CREDENTIALS)
# Phase 2: Minimal Claude Code LLM call via Vertex AI (optional if claude CLI present)

set -euo pipefail

echo "=== Intelliaide Prow CI Credential POC ==="

CRED_DIR="/var/run/claude-code-service-account"
CRED_FILE=""

for key in google-token token claude-prow; do
  candidate="${CRED_DIR}/${key}"
  if [[ -r "${candidate}" ]]; then
    CRED_FILE="${candidate}"
    echo "Found readable credential key: ${key}"
    break
  fi
done

if [[ -z "${CRED_FILE}" ]]; then
  echo "ERROR: No readable GCP credential found under ${CRED_DIR}"
  echo "Expected one of: google-token, token, claude-prow"
  if [[ -d "${CRED_DIR}" ]]; then
    echo "Available mount entries (names only):"
    find "${CRED_DIR}" -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null || ls -la "${CRED_DIR}"
  else
    echo "Mount directory ${CRED_DIR} is missing"
  fi
  exit 1
fi

export GOOGLE_APPLICATION_CREDENTIALS="${CRED_FILE}"
export CLAUDE_CODE_USE_VERTEX="${CLAUDE_CODE_USE_VERTEX:-1}"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-openshift-ci-prow-agents}"

echo "Vertex project: ${ANTHROPIC_VERTEX_PROJECT_ID}"
echo "Credential path: ${GOOGLE_APPLICATION_CREDENTIALS}"

echo ""
echo "=== Phase 1: Intelliaide-style GCP token acquisition ==="

python3 <<'PYEOF'
import os
import sys

try:
    import google.auth
    import google.auth.transport.requests
except ImportError:
    print("Installing google-auth for Intelliaide-compatible ADC check...")
    import subprocess
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "-q", "google-auth"],
        stdout=subprocess.DEVNULL,
    )
    import google.auth
    import google.auth.transport.requests

creds_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
if not creds_path or not os.path.isfile(creds_path):
    print(f"ERROR: GOOGLE_APPLICATION_CREDENTIALS not readable: {creds_path!r}")
    sys.exit(1)

scopes = ["https://www.googleapis.com/auth/cloud-platform"]
credentials, project = google.auth.default(scopes=scopes)
credentials.refresh(google.auth.transport.requests.Request())
if not credentials.token:
    print("ERROR: google-auth returned empty token")
    sys.exit(1)

print("SUCCESS: Obtained GCP access token via ADC (Intelliaide auth_type=gcloud path)")
print(f"ADC-detected project: {project or 'unknown'}")
PYEOF

echo ""
echo "=== Phase 2: Vertex LLM smoke test via Claude Code ==="

if ! command -v claude &>/dev/null; then
  echo "WARNING: claude CLI not found; skipping Phase 2"
  echo "Phase 1 confirms Intelliaide-compatible authentication in Prow CI."
  exit 0
fi

echo "Claude Code version: $(claude --version 2>/dev/null || echo unknown)"

RESPONSE_FILE="${ARTIFACT_DIR}/intelliaide-poc-response.txt"
LOG_FILE="${ARTIFACT_DIR}/intelliaide-poc-claude.log"

set +x
if ! timeout 300 claude \
  --model "${INTELLIAIDE_POC_MODEL:-claude-sonnet-4-6}" \
  -p "Reply with exactly the text POC_OK and nothing else." \
  --output-format text \
  > "${RESPONSE_FILE}" 2>"${LOG_FILE}"; then
  echo "ERROR: Claude Code LLM call failed (see ${LOG_FILE})"
  exit 1
fi

if grep -q "POC_OK" "${RESPONSE_FILE}"; then
  echo "SUCCESS: LLM responded with expected POC_OK marker"
else
  echo "ERROR: LLM call completed but POC_OK not found in response"
  echo "Response saved to ${RESPONSE_FILE}"
  exit 1
fi

echo ""
echo "=== Intelliaide Prow CI Credential POC complete ==="
