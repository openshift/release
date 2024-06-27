#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
source "${SHARED_DIR}/govc.sh"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
# check template in machineset.
check_result=0
template_config=$(yq-go r "${SHARED_DIR}/install-config.yaml" 'platform.vsphere.failureDomains[*].topology.template')
template_config=${template_config##*/}
template_ms=$(oc get machineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.spec.providerSpec.value.template')
template_ms=${template_ms##*/}
if [[ ${template_config} != "${template_ms}" ]]; then
    echo "ERROR: template specify in install-config is ${template_config},  not same as machineset's template ${template_ms}. please check"
    check_result=1
else 
    echo "INFO template specify in install-config is ${template_config}, same as machineset's template ${template_ms}. check successful "
fi


#vm template check:
mapfile -t  node_list < <(oc get node --no-headers | awk '{print $1}')
echo "Checking each node, make sure that node is deployed from template ${template_config}"
for node in "${node_list[@]}"; do
    echo "checking node ${node}..."
    vm_path=$(govc vm.info ${node} | grep Path | awk '{print $2}')

    events=$(govc events ${vm_path} | grep "${template_config}")
    echo "${events}"
    if [ -z "${events}" ]; then
	  echo "ERROR: check failed on node ${node}"
          check_result=1
    else
	  echo "INFO: check passed on node ${node}"
    fi
done

exit ${check_result}
