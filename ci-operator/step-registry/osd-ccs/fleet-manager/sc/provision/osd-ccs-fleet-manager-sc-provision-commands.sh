#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function wait_for_cluster()
{
    local cluster_name=$1

    start_time=$(date +"%s")
    while true; do
      sleep 60
      cluster_state=$(ocm get /api/osd_fleet_mgmt/v1/"${cluster_name}" -p search="region='${OSDFM_REGION}'" | jq -r '.items[0].status')
      echo "${cluster_name} state: ${cluster_state}"
      if [[ "${cluster_state}" == "ready" ]]; then
        wait_time=$[(date +"%s") - $start_time]
        echo "${cluster_name} reported as ready after ${wait_time} seconds"
        break
      fi
      if (( $(date +"%s") - $start_time >= $OSDFM_SC_CLUSTER_TIMEOUT )); then
        echo "error: Timed out while waiting for ${cluster_name} to be ready"
        exit 1
      fi
    done
    return 0
}

## Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${OSDFM_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in with OSDFM token
OCM_VERSION=$(ocm version)
OSDFM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/fleetmanager-token")
echo "Logging into ${OSDFM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
if [[ ! -z "${OSDFM_TOKEN}" ]]; then
  echo "Logging into ${OSDFM_LOGIN_ENV} with osdfm offline token"
  ocm login --url "${OSDFM_LOGIN_ENV}" --token "${OSDFM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OSDFM_TOKEN!"
  exit 1
fi

# Create SC
echo '{"region": "${OSDFM_REGION}", "cloud_provider": "aws"}' | ocm post /api/osd_fleet_mgmt/v1/service_clusters

# Check if Service Cluster is ready
echo "Waiting for Service Cluster ready..."
wait_for_cluster "service_clusters"

# Print Management Cluster info, there might be multiple MC
cluster_num=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.size')
if ((${cluster_num} > 1)); then
    echo "There are multiple MC and some in failure, print their states"
    for((i=0;i<${cluster_num};i++));
    do
        cluster_state=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.items['$i'].status')
        echo "Index $i MC is in ${cluster_state} state"
        if [[ "${cluster_state}" == "ready" ]]; then
            mc_ready_idx=$i
        fi
    done
fi

#Save MC kubeconfig
CLUSTER_ID=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.items['${mc_ready_idx}'].cluster_management_reference.cluster_id')
ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials | jq -r .kubeconfig > "${SHARED_DIR}/kubeconfig"
