#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Save current ClusterImagePolicy scopes as proper JSON for restoration
CURRENT_SCOPES=$(oc get clusterimagepolicy openshift -o json | jq -c '.spec.scopes')
if [[ -z "${CURRENT_SCOPES}" || "${CURRENT_SCOPES}" == "null" ]]; then
  echo "ERROR: Could not read ClusterImagePolicy scopes from cluster."
  exit 1
fi
echo "${CURRENT_SCOPES}" > "${SHARED_DIR}/original_cip_scopes.json"
echo "Original ClusterImagePolicy scopes: ${CURRENT_SCOPES}"

# Save current CVO overrides for restoration
CURRENT_OVERRIDES=$(oc get clusterversion version -o json 2>/dev/null | jq -c '.spec.overrides // []')
echo "${CURRENT_OVERRIDES}" > "${SHARED_DIR}/original_cvo_overrides.json"
echo "Original CVO overrides: ${CURRENT_OVERRIDES}"

# Check if we need to patch (only if ocp-v4.0-art-dev is in scopes)
if echo "${CURRENT_SCOPES}" | grep -q "ocp-v4.0-art-dev"; then
  # Append our override to existing overrides
  NEW_OVERRIDES=$(echo "${CURRENT_OVERRIDES}" | jq -c '. + [{"kind":"ClusterImagePolicy","group":"config.openshift.io","name":"openshift","namespace":"","unmanaged":true}]')

  echo "Adding CVO override to unmanage ClusterImagePolicy..."
  oc patch clusterversion version --type=merge \
    -p "{\"spec\":{\"overrides\":${NEW_OVERRIDES}}}"

  # Write marker immediately after CVO patch so restore runs even if policy patch fails
  echo "patched" > "${SHARED_DIR}/cip_patched"

  echo "Patching ClusterImagePolicy to allow unsigned nightly images..."
  oc patch clusterimagepolicy openshift --type=json \
    -p '[{"op":"replace","path":"/spec/scopes","value":["quay.io/openshift-release-dev/ocp-release"]}]'

  echo "Patched. Waiting 30s for CRI-O to pick up the policy change..."
  sleep 30

  echo "Cluster patched. ClusterImagePolicy now allows unsigned nightly images."
else
  echo "ClusterImagePolicy does not enforce ocp-v4.0-art-dev signatures. No patch needed."
fi
