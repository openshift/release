#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig



function checkMultizone() {
    check_result=0
    cpms_network=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.network.devices')
    cpms_workspace=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.workspace')
    cpms_template=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.template')
#check network,workspace and template field in cpms.
    if [[ ${cpms_network} == "null" ]] && [[ ${cpms_workspace} == "{}" ]] && [[ ${cpms_template} == "" ]]; then
        echo "INFO: For multi failure domains The network,workspace and template under cpms are empty, that's expected"
    else
	echo "ERROR: For multi failure domains The network,workspace and template under cpms should be empty. network is ${cpms_network},workspace is ${cpms_workspace},template is ${cpms_template}" 
        check_result=1
    fi
    
#check the name of failuredomains in cpms should be same with install-config.
    INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
    readarray -t zones_setting_from_config < <(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.vsphere.zones[*]')    
    fd_name_cpms=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.failureDomains.vsphere[].name' | sort -u)
    expected_fd_name=$(echo "${zones_setting_from_config[*]}" | xargs -n1 | sort -u | xargs)
    if [[ ${fd_name_cpms} == "${expected_fd_name}" ]]; then
	echo "INFO: The failure domain name are same between install_config and cmps"
    else
	echo "ERROR: The failure domain name are different between install_config and cmps. please check"
        check_result=1
    fi
    return ${check_result}
}


function checkSinglezone() {
        check_result=0
	node_name=$(oc get machines.machine.openshift.io -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=master --no-headers | awk '{print $1}' | head -n1)
	machine_workspace=$(oc get machine ${node_name} -n openshift-machine-api -ojson | jq -r '.spec.providerSpec.value.workspace')
	machine_template=$(oc get machine ${node_name} -n openshift-machine-api -ojson | jq -r '.spec.providerSpec.value.template')
	machine_network=$(oc get machine ${node_name} -n openshift-machine-api -ojson | jq -r '.spec.providerSpec.value.network.devices[].networkName')
        
	cpms_network=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.network.devices[].networkName')
	cpms_workspace=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.workspace')
        cpms_template=$(oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.template')
        if [[ ${machine_workspace} == "${cpms_workspace}" ]] && [[ ${machine_template} == "${cpms_template}" ]]  && [[ ${machine_network} == "${cpms_network}" ]]; then
	    echo "INFO: The network,workspace and template setting between cmps and machines are same. that's expected"
	else
	   check_result=1
	fi
    return ${check_result}
}

function checkTemplate() {

#check template in infrastructure should be populated.
    check_result=0
    infra_template=$(oc get infrastructure -ojson | jq -r '.items[].spec.platformSpec.vsphere.failureDomains[].topology.template')
    if [[ -n ${infra_template} ]]; then
        echo "INFO: The template is populated. template under infrastructure is ${infra_template}"
    else
        echo "ERROR: The template is empty, please check"
        check_result=1
    fi
    return ${check_result}

}

ocp_minor_version=$(oc version -ojson | jq -r '.openshiftVersion' | cut -d '.' -f2)

if (( ${ocp_minor_version} < 15 )); then
	echo "CPMS failureDomain check is only available on 4.15+ cluster, skip the check!"
        exit 0
fi
if [[ "${FEATURE_SET}" == "TechPreviewNoUpgrade" ]]; then
      echo "cpms spec:"
      oc get controlplanemachineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.machines_v1beta1_machine_openshift_io'
      checkTemplate
      INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
      readarray -t zones_setting_from_config < <(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.vsphere.zones[*]')
      if (( ${#zones_setting_from_config[@]} > 1 )); then
          checkMultizone
      else
	  checkSinglezone
      fi
fi
