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

# ocm login created files here that we now use to delete the cluster
export HOME=${SHARED_DIR}

if [[ ! -z "${SSO_CLIENT_ID}" && ! -z "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_URL} with SSO credentials"
  ocm login --url "${OCM_LOGIN_URL}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ ! -z "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_URL} with OCM token"
  ocm login --url "${OCM_LOGIN_URL}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to specify SSO_CLIENT_ID/SSO_CLIENT_SECRET or OCM_TOKEN!"
  exit 1
fi

CLUSTER_ID=$(cat "${HOME}/cluster-id")
echo "Deleting cluster-id: ${CLUSTER_ID}"

ocm delete "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"
echo "Waiting for cluster deletion..."
while ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" ; do
  sleep 60
done

echo "Cluster is no longer accessible; delete successful"
exit 0
