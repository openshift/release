#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
export KUBECONFIG=${SHARED_DIR}/kubeconfig
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS
check_result=0

machineset_name=$(oc get machineset -n openshift-machine-api --no-headers | head -n1 | awk '{print $1}')

rsp_config=$(yq-go r ${INSTALL_CONFIG} 'platform.vsphere.failureDomains[*].topology.resourcePool')

if [[ -n "$(oc get machineset -n openshift-machine-api ${machineset_name} -o json | jq -r .spec.template.spec.providerSpec.value.workspace | grep ${rsp_config})" ]];then
    echo "customized resourcePool found in machineset"
else
    echo "customized resourcePool not found in machineset"
    check_result=1
fi

if [[ -n "$(oc get cm cloud-provider-config -n openshift-config -o yaml | grep ${rsp_config})" ]];then
    echo "customized resourcePool found in cloud-porvider-config"
else
    echo "customized resourcePool not found in cloud-porvider-config"
    check_result=1
fi

exit ${check_result}

