#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_TYPE=${CLUSTER_TYPE:-"OSD"}
SUBSCRIPTION_TYPE=${SUBSCRIPTION_TYPE:-"standard"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
UPGRADED_TO_VERSION=${UPGRADED_TO_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP:-"stable"}
HOSTED_CP=${HOSTED_CP:-false}
EC_BUILD=${EC_BUILD:-false}

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Get the openshift version
if [[ -z "$OPENSHIFT_VERSION" ]] || [[ -z "$UPGRADED_TO_VERSION" ]]; then
  echo "The initiate/upgraded openshift versions must be set!"
  exit 1
fi

seach_pharse="raw_id like '$OPENSHIFT_VERSION%' and enabled='t' and available_upgrades is not '' and channel_group is '$CHANNEL_GROUP'"
if [[ "$CLUSTER_TYPE" == "ROSA" ]]; then
  seach_pharse="$seach_pharse and rosa_enabled='t'"
fi
if [[ "$HOSTED_CP" == "true" ]]; then
  seach_pharse="$seach_pharse and hosted_control_plane_enabled='t'"
fi
if [[ "$SUBSCRIPTION_TYPE" == "marketplace-gcp" ]]; then
  seach_pharse="$seach_pharse and gcp_marketplace_enabled='t'"
fi
if [[ "$EC_BUILD" == "true" ]]; then
  seach_pharse="$seach_pharse and raw_id like '%ec%'"
fi
echo "Search pharse: $seach_pharse"

versionList=$(ocm get "/api/clusters_mgmt/v1/versions" --parameter search="$seach_pharse" | jq -r '.items[].id')
version=$(echo "$versionList" | head -n 1)
if [[ -z "$version" ]]; then
  echo "No avaliable upgrade openshift version is found for $OPENSHIFT_VERSION!"
  exit 1
fi

echo "Choose the avaliable upgrade openshift version $version for cluster provision"
OPENSHIFT_VERSION=$(ocm get "/api/clusters_mgmt/v1/versions/$version" | jq -r '.raw_id')
echo "$OPENSHIFT_VERSION" > "${SHARED_DIR}/available_upgrade_version.txt"

ocm get "/api/clusters_mgmt/v1/versions/$version" | jq -r '.available_upgrades[]' > "${ARTIFACT_DIR}/available_upgrade_to_version_list.txt"
upgrade_to_version=$(cat "${ARTIFACT_DIR}/available_upgrade_to_version_list.txt" | grep ${UPGRADED_TO_VERSION} | tail -n 1 || true)
if [[ -z "$upgrade_to_version" ]]; then
  echo "No available upgraded_to openshift version is found for $UPGRADED_TO_VERSION!"
  exit 1
fi
echo $upgrade_to_version > "${SHARED_DIR}/available_upgraded_to_version.txt"
echo "Choose the openshift version $upgrade_to_version to be upgraded to"
