#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

# Run the actual local dev workflow commands
make run-k8s
make query-k8s-curl
make test-eval-k8s

# Verify at least one eval case passed (PASS count > 0)
if ! grep -q "PASS" test/evals/eval_output/summary.txt; then
  echo "[CI] No passing eval cases found in eval_output/summary.txt"
  exit 1
fi

echo "[CI] At least one eval case passed"
