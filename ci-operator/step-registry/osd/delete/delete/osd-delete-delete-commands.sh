#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ocm login created files here that we now use to delete the cluster
export HOME=${SHARED_DIR}

CLUSTER_ID=$(cat "${HOME}/cluster-id")
echo "Deleting cluster-id: ${CLUSTER_ID}"

ocm delete "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"
echo "Waiting for cluster deletion..."
while ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" ; do
  sleep 60
done

echo "Cluster is no longer accessible; delete successful"
exit 0
