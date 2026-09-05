#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
PATCHED_FLAG="${SHARED_DIR}/cip_patched"
ORIGINAL_SCOPES_FILE="${SHARED_DIR}/original_cip_scopes.json"
ORIGINAL_OVERRIDES_FILE="${SHARED_DIR}/original_cvo_overrides.json"

if [[ ! -f "${PATCHED_FLAG}" ]]; then
  echo "ClusterImagePolicy was not patched. Nothing to restore."
  exit 0
fi

# Restore ClusterImagePolicy scopes
if [[ -f "${ORIGINAL_SCOPES_FILE}" ]]; then
  ORIGINAL_SCOPES=$(cat "${ORIGINAL_SCOPES_FILE}")
  if echo "${ORIGINAL_SCOPES}" | jq empty 2>/dev/null; then
    echo "Restoring ClusterImagePolicy scopes to: ${ORIGINAL_SCOPES}"
    oc patch clusterimagepolicy openshift --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/scopes\",\"value\":${ORIGINAL_SCOPES}}]"
  else
    echo "Invalid backup scopes, skipping ClusterImagePolicy restore."
  fi
else
  echo "No scopes backup found, skipping ClusterImagePolicy restore."
fi

# Restore CVO overrides
if [[ -f "${ORIGINAL_OVERRIDES_FILE}" ]]; then
  ORIGINAL_OVERRIDES=$(cat "${ORIGINAL_OVERRIDES_FILE}")
  if echo "${ORIGINAL_OVERRIDES}" | jq empty 2>/dev/null; then
    if [[ "${ORIGINAL_OVERRIDES}" == "[]" ]]; then
      echo "Removing CVO overrides (original had none)..."
      oc patch clusterversion version --type=json \
        -p '[{"op":"remove","path":"/spec/overrides"}]' 2>/dev/null || true
    else
      echo "Restoring CVO overrides to: ${ORIGINAL_OVERRIDES}"
      oc patch clusterversion version --type=merge \
        -p "{\"spec\":{\"overrides\":${ORIGINAL_OVERRIDES}}}"
    fi
  else
    echo "Invalid backup overrides, skipping CVO restore."
  fi
else
  echo "No overrides backup found, skipping CVO restore."
fi

echo "ClusterImagePolicy restored to original state."
