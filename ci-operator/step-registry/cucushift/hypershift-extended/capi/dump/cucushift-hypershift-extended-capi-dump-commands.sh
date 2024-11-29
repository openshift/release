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

echo "dump rosa cluster info: ${CLUSTER_NAME}"
rosa describe cluster -c ${CLUSTER_NAME} > ${ARTIFACT_DIR}/${CLUSTER_NAME}.yaml
echo "dump capa logs"
capa_controller=$(oc get pod -n capa-system -lcontrol-plane=capa-controller-manager -ojsonpath='{.items[*].metadata.name}')
if [[ -n "${capa_controller}" ]] ; then
  oc logs -n capa-system ${capa_controller} > ${ARTIFACT_DIR}/${capa_controller}.logs
fi

echo "dump nodepool"
nodepool_name=$(cat "${SHARED_DIR}/rosa_nodepool")
rosa describe machinepool -c ${CLUSTER_NAME} --machinepool "${nodepool_name}" > ${ARTIFACT_DIR}/${nodepool_name}.yaml
