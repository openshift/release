#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

# Deprovision SC/MC
# Delete SC firstly otherwise SC will restart MC again
sc_cluster_id=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.items[0].cluster_management_reference.cluster_id')
ocm delete /api/osd_fleet_mgmt/v1/service_clusters/${sc_cluster_id}
# Delete MCs
cluster_num=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.size')
if ((${cluster_num} > 1)); then
    for((i=0;i<${cluster_num};i++));
    do
        echo "Delete MC for index $i"
        mc_cluster_id=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.items['$i'].cluster_management_reference.cluster_id')
        ocm delete /api/osd_fleet_mgmt/v1/management_clusters/${mc_cluster_id}
    done
fi

echo "Waiting for SC deletion..."
while true; do
  sleep 60
  cluster_num=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters -p search="region='${OSDFM_REGION}'" | jq -r '.size')
  if ((${cluster_num} == 0)); then
    break
  fi
done

echo "Delete successful"
exit 0