#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
# These two environment variables are coming from vsphere_context.sh and
# the file they are assigned to is not available in this step.
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"

check_result=0
infra_id=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)

function check_multi_vcenter() {
    local node_type=$1
    local check_result=0 nodes_list node_region node_zone fd_folder fd_datacenter fd_server fd_servers
    nodes_list=$(oc get nodes --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/${node_type} -o json | jq -r '.items[].metadata.name')
    readarray -t fd_servers < <(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains[*].server")
    for node in ${nodes_list}; do
        # shellcheck disable=SC2207
        label_info=($(oc get node ${node} --show-labels --no-headers | awk -F, '{print $(NF-1),$NF}'))
        node_region=$(echo ${label_info[0]} | awk -F= '{print $2}')
        node_zone=$(echo ${label_info[1]} | awk -F= '{print $2}')
        echo "checking labels on node ${node}, label region: ${node_region}, label zone: ${node_zone}"
        fd_datacenter=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).topology.datacenter")
        [[ -z "${fd_datacenter}" ]] && fd_datacenter=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.datacenter")
	fd_folder=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).topology.folder")
	fd_server=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).server")
        [[ -z "${fd_folder}" ]] && fd_folder="/${fd_datacenter}/vm/${infra_id}"	
	if [[ -n "$(govc ls ${fd_folder}/${node})"  ]];then
            echo "INFO: ${node} is created under correct path: ${fd_folder}"
	fi
	machine_server=$(oc get machines.machine.openshift.io ${node} -n openshift-machine-api -ojson | grep server | awk -F ': ' '{print $2}' | sed 's/\"//g')
	if [[ "${machine_server}" == "${fd_server}" ]] && [[ ${#fd_servers[@]} -gt 1 ]]; then
            echo "the vcenter specified in install-config is same with machine"
	else
	    echo "the vcenter specified in install-config is different from the machine"
	    check_result=1
	fi
    done
    return ${check_result}
}	

check_multi_vcenter "master" || check_result=1
check_multi_vcenter "worker" || check_result=1

exit ${check_result}
