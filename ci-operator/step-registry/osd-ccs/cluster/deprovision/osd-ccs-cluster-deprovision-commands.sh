#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
if [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
elif [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
else
  echo "Cannot login! You need to securely supply an ocm-token or SSO credentials!"
  exit 1
fi

# Deprovision cluster
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
echo "Deleting cluster: ${CLUSTER_ID}"

echo "Fetching installation logs of the cluster ${CLUSTER_ID}..."
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.cluster_install.log" || echo "error: Unable to pull installation log."

ocm delete "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"
echo "Waiting for cluster deletion..."
while ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" ; do
  sleep 60
done

echo "Cluster is no longer accessible; delete successful"
exit 0
