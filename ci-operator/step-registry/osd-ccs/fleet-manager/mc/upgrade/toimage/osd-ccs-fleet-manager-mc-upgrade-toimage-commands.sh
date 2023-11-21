#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo "Generating the Junit for upgrade"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="0">
  <testcase classname="cluster upgrade" name="upgrade should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="1">
  <testcase classname="cluster upgrade" name="upgrade should succeed">
    <failure message="">management cluster upgrade failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function upgrade () {
  function get_highest_z_version_upgrade () {
    AVAILABLE_UPGRADE_VERSIONS=$1
    CURRENT_V=$2
    VERSIONS_SIZE=$3
    IFS='.' read -r -a CURRENT_SEPARATED <<< "$CURRENT_V"
    CURRENT_HIGHEST_PATCH=${CURRENT_SEPARATED[2]}
    CURRENT_HIGHEST_MINOR=${CURRENT_SEPARATED[1]}
    CURRENT_HIGHEST_MAJOR=${CURRENT_SEPARATED[0]}
    for ((i=0; i<"$VERSIONS_SIZE"; i++)); do
      VERSION=$(jq -n "$AVAILABLE_UPGRADE_VERSIONS" | jq -r .[$i])
      IFS='.' read -r -a CURRENT_SEPARATED_UPGRADE_VERSION <<< "${VERSION}"
      if [ "${CURRENT_SEPARATED_UPGRADE_VERSION[0]}" == "$CURRENT_HIGHEST_MAJOR" ] && [ "${CURRENT_SEPARATED_UPGRADE_VERSION[1]}" == "$CURRENT_HIGHEST_MINOR" ] && [ "${CURRENT_SEPARATED_UPGRADE_VERSION[2]}" \> "$CURRENT_HIGHEST_PATCH" ]; then
        CURRENT_HIGHEST_PATCH=${CURRENT_SEPARATED_UPGRADE_VERSION[2]}
        CURRENT_HIGHEST_MINOR=${CURRENT_SEPARATED_UPGRADE_VERSION[1]}
        CURRENT_HIGHEST_MAJOR=${CURRENT_SEPARATED_UPGRADE_VERSION[0]}
        HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION="$CURRENT_HIGHEST_MAJOR.$CURRENT_HIGHEST_MINOR.$CURRENT_HIGHEST_PATCH"
      fi
    done
  }
  mc_ocm_cluster_id=$(cat ${SHARED_DIR}/osd-fm-mc-id)
  KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  CURRENT_VERSION=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_ocm_cluster_id" | jq -r .version.raw_id)
  AVAILABLE_UPGRADES=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_ocm_cluster_id" | jq -r .version.available_upgrades)
  NO_OF_VERSIONS=$(jq -n "$AVAILABLE_UPGRADES" | jq '. | length')
  HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION=""
  get_highest_z_version_upgrade "${AVAILABLE_UPGRADES[@]}" "$CURRENT_VERSION" "$NO_OF_VERSIONS"
  echo 'HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION'
  echo "$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION"

  if [ "$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION" == "" ]; then
    echo "No available upgrades found"
    exit 1
  else
    echo "Available version upgrades are: $AVAILABLE_UPGRADES"
    echo "Upgrading openshift version of MC with ocm API ID: $mc_ocm_cluster_id to version: $HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION"
    oc --kubeconfig "$KUBECONFIG" adm upgrade --to="$HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION"
    echo "${HIGHEST_AVAILABLE_PATCH_UPGRADE_VERSION}" > "${SHARED_DIR}/osd-fm-mc-available-upgrade-version"
  fi
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

# check mc status

upgrade

