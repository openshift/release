#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM


function upgrade_complete_check () {
  mc_ocm_cluster_id=$(cat ${SHARED_DIR}/osd-fm-mc-id)
  KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  AVAILABLE_UPGRADE_VERSION=$(cat ${SHARED_DIR}/osd-fm-mc-available-upgrade-version)
  counter=0
  while true; do
    sleep 60
    CLUSTER_VERSION_INFO=$(oc --kubeconfig "$KUBECONFIG" get clusterversion | tail -1)
    CURRENT_VERSION=$(echo "$CLUSTER_VERSION_INFO" | awk '{print $2}')
    UPGRADE_PROGRESSING=$(echo "$CLUSTER_VERSION_INFO" | awk '{print $4}')
    UPGRADE_STATUS=$(echo "$CLUSTER_VERSION_INFO" | awk '{$1=$2=$3=$4=$5=""; print $0}')
    echo "Waiting for MC openshift version to be: $FIRST_AVAILABLE_UPGRADE_VERSION. Current version is: $CURRENT_VERSION. Upgrade in progress: $UPGRADE_PROGRESSING"
    echo "Upgrade status: $UPGRADE_STATUS"
    if [ "${CURRENT_VERSION}" == "$FIRST_AVAILABLE_UPGRADE_VERSION" ] && [ "$UPGRADE_PROGRESSING" != "True" ]; then
      echo "Successfully upgraded MC with ocm API ID: $mc_ocm_cluster_id to $FIRST_AVAILABLE_UPGRADE_VERSION"
      break
    fi
    counter=$(($counter+1))
    if [[ $counter -gt 30 ]] ; then
      echo "Error: the target MC version $AVAILABLE_UPGRADE_VERSION is not completed, current version is $CURRENT_VERSION"
      exit 1
    fi
  done
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

# TODO check mc status

upgrade_complete_check

