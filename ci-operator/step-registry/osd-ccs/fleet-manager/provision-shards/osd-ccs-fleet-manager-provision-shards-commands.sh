#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_SECTOR=${CLUSTER_SECTOR:-"canary"}
REGION=${REGION:-$LEASED_RESOURCE}

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Get the rovision shard list by region, by sector
echo "Get the ${CLUSTER_SECTOR} provision shard list in ${REGION} ..."
psList=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${REGION}' and status is 'ready' " | jq -r '.items[].provision_shard_reference.id')
if [[ -z "$psList" ]]; then
  echo "No available provision shard!"
  exit 1
fi

echo -e "Available provision shards:\n${psList}"
echo "${psList}" > "${SHARED_DIR}/provision_shard_ids"
