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

if [[ -z ${rsp_config} ]];then
    echo "no resouce pool specified in install-config,skip check"
    exit 0
fi

mapfile -t node_lists < <(oc get node --no-headers | awk '{print $1}')
mapfile -t rsp_vm_lists < <(govc pool.info -json ${rsp_config} | jq -r '.ResourcePools[].Vm[] | join(":")' | xargs govc ls -L | awk -F'/' '{print $NF}')
#check if vm locate in resource pool
for node in "${node_lists[@]}"; do
    if [[ "${rsp_vm_lists[*]}" =~ ${node} ]];then
        echo "node ${node} found in resouce pool"
    else 
	echo "node ${node} not found in resouce pool, please check"
	check_result=1
    fi
done

if oc get machineset -n openshift-machine-api ${machineset_name} -o json | jq -r .spec.template.spec.providerSpec.value.workspace | grep -q ${rsp_config};then
    echo "customized resourcePool found in machineset"
else
    echo "customized resourcePool not found in machineset, please check"
    check_result=1
fi

if oc get cm cloud-provider-config -n openshift-config -o yaml | grep -q ${rsp_config};then
    echo "customized resourcePool found in cloud-porvider-config"
else
    echo "customized resourcePool not  found in cloud-porvider-config, please check"
    check_result=1
fi

exit ${check_result}

