#!/bin/bash

set -euo pipefail

CREDENTIALS_FILE="/var/run/secrets/rhoai-quay-pull/pull-secret"

if [[ ! -r "${CREDENTIALS_FILE}" ]]; then
  echo "ERROR: Missing RHOAI Quay credentials at ${CREDENTIALS_FILE}"
  exit 1
fi

if oc get secret pull-secret -n openshift-config; then
  echo "Adding RHOAI Quay robot account to the global cluster pull secret"
else
  echo "ERROR: Global cluster pull secret does not exist."
  exit 255
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cluster_pull_secret_file="${TMP_DIR}/cluster-pull-secret.json"
rhoai_pull_secret_file="${TMP_DIR}/rhoai-pull-secret.json"
merged_pull_secret_file="${TMP_DIR}/merged-pull-secret.json"
auth_file="${TMP_DIR}/rhoai-auth.b64"

NUM_WORKERS="$(oc get mcp worker -ojsonpath='{.status.machineCount}')"

echo "Get current global cluster pull secret"
oc get secret pull-secret -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' \
  > "${cluster_pull_secret_file}"

# Disable tracing while handling credentials
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

# Vault key pull-secret already holds base64(user:token); do not base64 again
AUTH="$(tr -d '\n\r' < "${CREDENTIALS_FILE}")"
if [[ -z "${AUTH}" ]]; then
  echo "ERROR: RHOAI Quay credentials file is empty"
  exit 1
fi

if ! DECODED="$(printf '%s' "${AUTH}" | base64 -d 2>/dev/null)" || [[ "${DECODED}" != *:* ]]; then
  echo "ERROR: RHOAI Quay credentials must be base64(user:token)"
  exit 1
fi
unset DECODED

printf '%s' "${AUTH}" > "${auth_file}"
unset AUTH

echo "Get RHOAI Quay credentials"
jq -n --rawfile auth "${auth_file}" \
  '{"auths":{"quay.io/rhoai":{"auth":$auth,"email":""}}}' \
  > "${rhoai_pull_secret_file}"

# Compare the full quay.io/rhoai credential object (not only .auth)
if jq -e --slurpfile rhoai "${rhoai_pull_secret_file}" \
  '(.auths["quay.io/rhoai"] // null) == $rhoai[0].auths["quay.io/rhoai"]' \
  "${cluster_pull_secret_file}" >/dev/null; then
  pull_secret_changed=false
else
  pull_secret_changed=true
fi

# Replace the quay.io/rhoai entry entirely so stale fields (e.g. identitytoken) are dropped
echo "Merge RHOAI Quay credentials and the global cluster pull secret"
jq --slurpfile rhoai "${rhoai_pull_secret_file}" \
  '.auths["quay.io/rhoai"] = $rhoai[0].auths["quay.io/rhoai"]' \
  "${cluster_pull_secret_file}" \
  > "${merged_pull_secret_file}"

$WAS_TRACING && set -x

if [[ "${pull_secret_changed}" == "false" ]]; then
  echo "quay.io/rhoai credentials already present and unchanged; skipping pull-secret update and MCP waits"
  exit 0
fi

echo "Update the global cluster pull secret with the new merged credentials"
oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson="${merged_pull_secret_file}"

echo "Wait until the configuration is applied"
if [[ "${NUM_WORKERS}" != "0" ]]; then
  oc wait mcp worker --for='condition=UPDATING=True' --timeout=300s
else
  echo "SNO or Compact cluster. We don't wait for the worker pool to start configuring"
fi
oc wait mcp master --for='condition=UPDATING=True' --timeout=300s

if [[ "${NUM_WORKERS}" != "0" ]]; then
  oc wait mcp worker --for='condition=UPDATED=True' --timeout=600s
else
  echo "SNO or Compact cluster. We don't wait for the worker pool to be configured"
fi
oc wait mcp master --for='condition=UPDATED=True' --timeout=600s
