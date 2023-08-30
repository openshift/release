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

# Deprovision cluster
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
echo "Deleting cluster: ${CLUSTER_ID}"
# Sleep 6 hours for debugging
sleep 21600

ocm delete "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"
echo "Waiting for cluster deletion..."
while ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" ; do
  sleep 60
done

echo "Cluster is no longer accessible; delete successful"
exit 0
