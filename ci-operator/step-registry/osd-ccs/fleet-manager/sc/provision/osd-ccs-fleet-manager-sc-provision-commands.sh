#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function wait_for_cluster()
{
    while true; do
      sleep 60
      cluster_state=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.items[0].status')
      echo "service cluster state: ${cluster_state}"
      if [[ "${cluster_state}" == "ready" ]]; then
        echo "service cluster reported as ready"
        break
      fi
    done
    return 0
}

#Set up region
OSDFM_REGION=${LEASED_RESOURCE}
echo "region: ${LEASED_RESOURCE}"
if [[ "${OSDFM_REGION}" != "ap-northeast-1" ]]; then
  echo "${OSDFM_REGION} is not ap-northeast-1, exit"
  exit 1
fi

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
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
if [[ ! -z "${OSDFM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with osdfm offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OSDFM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OSDFM_TOKEN!"
  exit 1
fi

# Check if SC already exists
sc_cluster_num=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.total')
if ((${sc_cluster_num} > 0)); then
  sc_cluster_id=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.items[0].id')
  echo "Service Cluster '${sc_cluster_id}' already exists in region '${OSDFM_REGION}', exit"
  exit 1
fi

# Create SC
sc_cluster_id=$(echo '{"region": "'${OSDFM_REGION}'", "cloud_provider": "aws"}' | ocm post /api/osd_fleet_mgmt/v1/service_clusters | jq -r '.id')
# Save Service Cluster info
echo "Service Cluster fm id:${sc_cluster_id}"
echo "${sc_cluster_id}" > "${SHARED_DIR}/osd-fm-sc-id"

# Check if Service Cluster is ready
echo "Waiting for Service Cluster ready..."
wait_for_cluster

# Save kubeconfig of sc
sc_ocm_cluster_id=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters/$sc_cluster_id | jq -r .cluster_management_reference.cluster_id)
echo "Save kubeconfig and ocm cluster ID for Service Cluster:${sc_ocm_cluster_id}"
ocm get /api/clusters_mgmt/v1/clusters/${sc_ocm_cluster_id}/credentials | jq -r .kubeconfig > "${SHARED_DIR}/hs-sc.kubeconfig"
echo "${sc_ocm_cluster_id}" > "${SHARED_DIR}/ocm-sc-id"

# Save MC kubeconfig and cluster info
mc_ocm_cluster=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters -p search="parent.id='${sc_cluster_id}' and status is 'ready'" -p size=1)
mc_ocm_cluster_id=$(echo $mc_ocm_cluster | jq -r '.items[0].cluster_management_reference.cluster_id')
mc_cluster_id=$(echo $mc_ocm_cluster | jq -r '.items[0].id')
echo "Management Cluster fm id:${mc_cluster_id}"
echo "Save ocm and osdfm cluster ID for MC with fm id:${mc_cluster_id}"
echo "${mc_cluster_id}" > "${SHARED_DIR}/osd-fm-mc-id"
echo "${mc_ocm_cluster_id}" > "${SHARED_DIR}/ocm-mc-id"

echo "Save kubeconfig for Management Cluster:${mc_ocm_cluster_id}"
if [[ -z "${mc_ocm_cluster_id}" ]]; then
  echo "No ready MC, Exit..."
  exit 1
fi
ocm get /api/clusters_mgmt/v1/clusters/${mc_ocm_cluster_id}/credentials | jq -r .kubeconfig > "${SHARED_DIR}/hs-mc.kubeconfig"
