#!/bin/bash

set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function rosa_login() {
    # ROSA_VERSION=$(rosa version)
    ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")

    if [[ ! -z "${ROSA_TOKEN}" ]]; then
      echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
      rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
      ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
    else
      echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
      exit 1
    fi
}

set_proxy
rosa_login

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION=${REGION}
export AWS_PAGER=""

# get cluster namesapce
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
if [[ -z "${CLUSTER_NAME}" ]] ; then
  echo "Error: cluster name not found"
  exit 1
fi

read -r namespace _ _  <<< "$(oc get cluster -A | grep ${CLUSTER_NAME})"
if [[ -z "${namespace}" ]]; then
  echo "capi cluster name not found error, ${CLUSTER_NAME}"
  exit 1
fi

echo "upgrade rosamachinepool"
rosacontrolplane_name=$(oc get cluster "${CLUSTER_NAME}" -n "${namespace}" -ojsonpath='{.spec.controlPlaneRef.name}')
cp_version=$(oc get rosacontrolplane ${rosacontrolplane_name} -n ${namespace} -ojsonpath='{.spec.version}')

machinepool=$(cat "${SHARED_DIR}/capi_machinepool")
rosamachinepool=$(oc get MachinePool -n "${namespace}" "${machinepool}" -ojsonpath='{.spec.template.spec.infrastructureRef.name}')
np_version=$(oc get rosamachinepool "${rosamachinepool}" -n "${namespace}" -ojsonpath='{.status.version}')

if [[ "X${cp_version}" == "X${np_version}" ]] ; then
  echo "rosamachinepool version is same as rosacontrolplane ${cp_version} ${np_version}"
  exit 1
fi

oc patch -n "${namespace}" --type=merge --patch='{"spec":{"updateConfig":{"rollingUpdate":{"maxSurge": 2, "maxUnavailable": 3}}}}' rosamachinepool/${rosamachinepool}
oc patch -n "${namespace}" --type=merge --patch='{"spec":{"version":"'"${cp_version}"'"}}' rosamachinepool/${rosamachinepool}
new_version=$(oc get rosamachinepool ${rosamachinepool} -n ${namespace} -ojsonpath='{.spec.version}')
echo "now rosamachinepool version is ${new_version}"

nodepool=$(oc get rosamachinepool "${rosamachinepool}" -n "${namespace}" -ojsonpath='{.spec.nodePoolName}')
CLUSTER_ID=$(cat $SHARED_DIR/cluster-id)
start_time=$(date +"%s")
while true; do
  sleep 300
  mp_version=$(rosa describe machinepool -c ${CLUSTER_ID} --machinepool ${nodepool}  -o json | jq -r '.version.raw_id')
  echo "rosa hcp mp version: ${mp_version}"
  if [[ "${mp_version}" == "${new_version}" ]]; then
    break
  fi
  if (( $(date +"%s") - $start_time >= $CLUSTER_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster np upgrade ${mp_version}"
    exit 1
  fi
done

echo "rosa hcp np upgrade done"


