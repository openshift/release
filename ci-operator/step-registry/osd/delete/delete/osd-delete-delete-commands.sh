#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id")
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret")

# ocm login created files here that we now use to delete the cluster
export HOME=${SHARED_DIR}

echo "Logging into ${OCM_LOGIN_URL} SSO"
ocm login --url "${OCM_LOGIN_URL}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"

CLUSTER_ID=$(cat "${HOME}/cluster-id")
echo "Deleting cluster-id: ${CLUSTER_ID}"

ocm delete "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"
echo "Waiting for cluster deletion..."
while ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" ; do
  sleep 60
done

echo "Cluster is no longer accessible; delete successful"
exit 0
