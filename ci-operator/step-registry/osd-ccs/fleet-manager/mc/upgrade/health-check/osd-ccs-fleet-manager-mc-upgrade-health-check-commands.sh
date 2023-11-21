#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function check_ho_connection() {
  hc_name=$(oc get hc -n clusters --ignore-not-found -ojsonpath='{.items[].metadata.name}')
  if [ -z "$hc_name" ] ; then
    echo "no hostedcluster found, skip hc health check"
    return 0
  fi

  counter=0
  while true ; do
    echo "-------------->"
    oc get pod -n hypershift
    oc logs -n hypershift -lapp=operator --tail=-1 | head -1
    echo "-------------->"
    oc get pod -n clusters-${hc_name} -owide

    if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]] ; then
    echo "--------------> check hostedcluster apiserver connection"
    oc --kubeconfig=${SHARED_DIR}/nested_kubeconfig get clusterversion
    oc --kubeconfig=${SHARED_DIR}/nested_kubeconfig get co
    fi
    echo "--------------> $count"
    date
    sleep 5
    counter=$(($counter+1))
    # 20min
    if [[ $counter -gt 240 ]] ; then
      break
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

# check mc status
mc_ocm_cluster_id=$(cat ${SHARED_DIR}/osd-fm-mc-id)
export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
AVAILABLE_UPGRADES=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_ocm_cluster_id" | jq -r .version.available_upgrades)

# todo

# this is not correct, because we don't know when the node upgrade begins
# the check is only meaningful when the mc worker nodes begin to upgrade (rolling upgrade)
check_ho_connection



