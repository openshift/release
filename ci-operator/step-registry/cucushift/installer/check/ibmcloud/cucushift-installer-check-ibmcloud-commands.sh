#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#OCP-47390 - [IPI-on-IBMCloud] Install cluster with "install-config.yaml" last step
function checkProviderType {
    local platformStatusFile="${ARTIFACT_DIR}/platformStatus"
    oc get infrastructure/cluster -o yaml > ${platformStatusFile}
    yq-go r ${platformStatusFile} 'status.platformStatus'
    providerType=$(yq-go r ${platformStatusFile} 'status.platformStatus.ibmcloud.providerType')
    if [[ ${providerType} != "VPC" ]]; then
        echo "ERROR: ${providerType} is not expected providerType [VPC]!!"
        return 1
    else 
        return 0
    fi
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

checkProviderType

exit $?