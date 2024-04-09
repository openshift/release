#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
source "${SHARED_DIR}/govc.sh"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
# check template in cpms and machineset
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

ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if (( ${ocp_minor_version} > 15 )); then
	template_cpms=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.template')
        template_cpms=${template_cpms##*/}
        if [[ ${template_config} != "${template_cpms}" ]]; then
             echo "ERROR: template specify in install-config is ${template_config},  not same as template in cpms ${template_cpms}. please check"
         check_result=1
        else 
             echo "INFO template specify in install-config is ${template_config}, same as template in cpms ${template_cpms}. check successful "
        fi
else 
        echo "CPMS on vpshere is GA on 4.16, and CPMS template check is only available on 4.16+ cluster, skip the check!"
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
