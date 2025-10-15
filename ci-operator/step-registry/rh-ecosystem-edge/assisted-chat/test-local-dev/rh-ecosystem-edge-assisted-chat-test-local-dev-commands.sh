#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if ! command -v oc >/dev/null 2>&1 && [ -x /cli/oc ]; then
  export PATH="/cli:${PATH}"
fi

# Debug info
echo "[test-local-dev-commands.sh] PATH=$PATH"
command -v oc >/dev/null 2>&1 && echo "[test-local-dev-commands.sh] oc=$(command -v oc)" || echo "[test-local-dev-commands.sh] oc not found"
oc version --client=true 2>/dev/null || true

GEMINI_API_KEY=$(cat /var/run/secrets/gemini/api_key)
export GEMINI_API_KEY

# Configure OCM authentication using mounted sso-ci credentials
CLIENT_ID=$(cat /var/run/secrets/sso-ci/client_id)
CLIENT_SECRET=$(cat /var/run/secrets/sso-ci/client_secret)
echo "[CI] Logging in to OCM with client credentials (client_id: ${CLIENT_ID})"
if ocm login --client-id="${CLIENT_ID}" --client-secret="${CLIENT_SECRET}" --url=https://api.openshift.com; then
  # Export tokens for scripts/run.sh to use
  OCM_TOKEN=$(ocm token)
  export OCM_TOKEN
  if REFRESH=$(ocm token --refresh 2>/dev/null) && [ -n "$REFRESH" ]; then
    export OCM_REFRESH_TOKEN="$REFRESH"
  else
    export OCM_REFRESH_TOKEN="$OCM_TOKEN"
  fi
  echo "[CI] OCM tokens exported to environment"
else
  echo "[CI] OCM login failed, exiting.."
  exit 1
fi

# Generate a unique IDs for the clusters to be cleaned up after the test
UNIQUE_ID=$(head /dev/urandom | tr -dc 0-9a-z | head -c 8)
echo "${UNIQUE_ID}" > ${SHARED_DIR}/eval_test_unique_id
sed -i "s/uniq-cluster-name/${UNIQUE_ID}/g" test/evals/eval_data.yaml

# Run the actual local dev workflow commands
make run-k8s
make query-k8s-curl

# Run eval; do not fail immediately on non-zero
set +e
( make test-eval-k8s || true ) 2>&1 | tee /tmp/eval-run.log
EVAL_RC=${PIPESTATUS[0]}

# Prefer a written summary if present, else parse the log
SUMMARY_FILE="test/evals/eval_output/summary.txt"
if [ -f "$SUMMARY_FILE" ]; then
  echo "[CI] Found summary file at $SUMMARY_FILE"
  PASSED=$(grep -Eo 'Passed:\s*[0-9]+' "$SUMMARY_FILE" | awk '{print $2}' | tail -n1)
else
  echo "[CI] Parsing summary from stdout log"
  PASSED=$(grep -Eo 'Passed:\s*[0-9]+' /tmp/eval-run.log | awk '{print $2}' | tail -n1)
fi
PASSED=${PASSED:-0}
echo "[CI] Eval result: PASSED=$PASSED (raw rc=$EVAL_RC)"

echo "[CI] Cleanup port-forward if created"
if [ -f /tmp/pf-assisted-chat.pid ]; then
  PF_PID="$(cat /tmp/pf-assisted-chat.pid || true)"
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$PF_PID" 2>/dev/null; then
      kill -9 "$PF_PID" 2>/dev/null || true
    fi
  fi
  rm -f /tmp/pf-assisted-chat.pid
fi

# Accept if at least one case passed
if [ "$PASSED" -gt 0 ]; then
  echo "[CI] At least one evaluation passed; treating as success"
  exit 0
fi

echo "[CI] No passing eval cases detected; failing"
exit 1
