#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function wait_for_cluster()
{
  local cluster_type=$1
  local cluster_id=$2
  local expected_statuses=$3

  while true; do
    sleep 30
    cluster_state=$(ocm get /api/osd_fleet_mgmt/v1/${cluster_type}/${cluster_id} | jq -r '.status')
    echo "${cluster_type} status: ${cluster_state}"
    if printf '%s\0' "${expected_statuses[@]}" | grep -qwz $cluster_state; then
      printf "%s status found within the list of expected statuses: %s" "${cluster_type}" "${expected_statuses[@]}"
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

# Deprovision SC/MC
# Delete SC firstly otherwise SC will restart MC again
sc_cluster_id=$(cat ${SHARED_DIR}/osd-fm-sc-id)
echo "Delete SC ${sc_cluster_id}"
ocm delete /api/osd_fleet_mgmt/v1/service_clusters/${sc_cluster_id}

# Delete MCs
mc_cluster_num=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters -p search="parent.id='${sc_cluster_id}'" | jq -r '.total')
for((i=0;i<${mc_cluster_num};i++));
do
  mc_cluster_id=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters -p search="parent.id='${sc_cluster_id}'" | jq -r '.items['$i'].id')
  echo "Delete MC ${mc_cluster_id}"
  ocm delete /api/osd_fleet_mgmt/v1/management_clusters/${mc_cluster_id}
  #Ack MC delete
  wait_for_cluster management_clusters ${mc_cluster_id} "(cleanup_ack_pending)"
  ocm delete /api/osd_fleet_mgmt/v1/management_clusters/${mc_cluster_id}/ack
  wait_for_cluster management_clusters ${mc_cluster_id} "(cleanup_network, cleanup_account)"
done

#Ack SC delete
wait_for_cluster service_clusters ${sc_cluster_id} "(cleanup_ack_pending)"
ocm delete /api/osd_fleet_mgmt/v1/service_clusters/${sc_cluster_id}/ack

echo "Waiting for SC deletion..."
while ocm get /api/osd_fleet_mgmt/v1/service_clusters/${sc_cluster_id} ; do
  sleep 60
done

echo "SC is no longer accessible; delete successful"
exit 0
