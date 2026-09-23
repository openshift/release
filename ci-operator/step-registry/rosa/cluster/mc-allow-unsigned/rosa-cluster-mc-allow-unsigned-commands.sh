#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login to OCM!"
  exit 1
fi

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
echo "Getting management cluster for HCP ${CLUSTER_ID}..."

MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard | jq -r .management_cluster)
MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r .items[0].id)

if [[ -z "${MC_CLUSTER_ID}" || "${MC_CLUSTER_ID}" == "null" ]]; then
  echo "Failed to find MC cluster ID for ${MC_NAME}"
  exit 1
fi

echo "MC: ${MC_NAME} (${MC_CLUSTER_ID})"

MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${MC_KUBECONFIG}"

# Save current ClusterImagePolicy scopes as proper JSON for restoration
CURRENT_SCOPES=$(KUBECONFIG="${MC_KUBECONFIG}" oc get clusterimagepolicy openshift -o json | jq -c '.spec.scopes')
if [[ -z "${CURRENT_SCOPES}" || "${CURRENT_SCOPES}" == "null" ]]; then
  echo "ERROR: Could not read ClusterImagePolicy scopes from MC."
  exit 1
fi
echo "${CURRENT_SCOPES}" > "${SHARED_DIR}/mc-image-policy-original-scopes.json"
echo "Original ClusterImagePolicy scopes: ${CURRENT_SCOPES}"

# Save current CVO overrides for restoration
CURRENT_OVERRIDES=$(KUBECONFIG="${MC_KUBECONFIG}" oc get clusterversion version -o json 2>/dev/null | jq -c '.spec.overrides // []')
echo "${CURRENT_OVERRIDES}" > "${SHARED_DIR}/mc-cvo-original-overrides.json"
echo "Original CVO overrides: ${CURRENT_OVERRIDES}"

# Check if we need to patch (only if ocp-v4.0-art-dev is in scopes)
if echo "${CURRENT_SCOPES}" | grep -q "ocp-v4.0-art-dev"; then
  # Append our override to existing overrides
  NEW_OVERRIDES=$(echo "${CURRENT_OVERRIDES}" | jq -c '. + [{"kind":"ClusterImagePolicy","group":"config.openshift.io","name":"openshift","namespace":"","unmanaged":true}]')

  echo "Adding CVO override to unmanage ClusterImagePolicy..."
  KUBECONFIG="${MC_KUBECONFIG}" oc patch clusterversion version --type=merge \
    -p "{\"spec\":{\"overrides\":${NEW_OVERRIDES}}}"

  # Write marker immediately after CVO patch so restore runs even if policy patch fails
  echo "patched" > "${SHARED_DIR}/mc-image-policy-patched"

  echo "Patching ClusterImagePolicy to allow unsigned nightly images..."
  KUBECONFIG="${MC_KUBECONFIG}" oc patch clusterimagepolicy openshift --type=json \
    -p '[{"op":"replace","path":"/spec/scopes","value":["quay.io/openshift-release-dev/ocp-release"]}]'

  echo "Patched. Waiting 30s for CRI-O to pick up the policy change..."
  sleep 30

  # Delete any stuck ImagePullBackOff pods in the HCP namespace so they get recreated
  HCP_NS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get pods -A 2>/dev/null | grep "${CLUSTER_ID}" | head -1 | awk '{print $1}' || true)
  if [[ -n "${HCP_NS}" ]]; then
    echo "Deleting stuck pods in ${HCP_NS}..."
    KUBECONFIG="${MC_KUBECONFIG}" oc delete pods -n "${HCP_NS}" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
    echo "Waiting 30s for replacement pods..."
    sleep 30
  fi

  echo "MC patched. ClusterImagePolicy now allows unsigned nightly images."
else
  echo "ClusterImagePolicy does not enforce ocp-v4.0-art-dev signatures. No patch needed."
fi
