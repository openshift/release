#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Get the kubeconfig of the management cluster who manages the hosted cluster
echo "Get the kubeconfig of the manangement cluster ..."
HOSTED_CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/${HOSTED_CLUSTER_ID}/provision_shard | jq -r .management_cluster)
MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r .items[0].id)
echo "${MC_NAME}" > "${SHARED_DIR}/mc-cluster-name"
if [[ -z "$MC_CLUSTER_ID" ]]; then
  echo "Failed to get the cluster id of the manangement cluster!"
  exit 1
fi

MC_KUBECONFIG_FILE="${SHARED_DIR}/hs-mc.kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${MC_KUBECONFIG_FILE}"

echo "MGMT ClusterName: ${MC_NAME}"
echo "MGMT ClusterID: ${MC_CLUSTER_ID}"
echo "MGMT Kubeconfig File: ${MC_KUBECONFIG_FILE}"
