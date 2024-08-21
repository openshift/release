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
readarray -t zones_name_from_config < <(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains[*].name")
infra_id=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)

function check_label_vmcluster() {

    local node_type=$1 node_fd_list=$2
    local check_result=0 nodes_list node_region node_zone fd_region fd_name fd_folder fd_computeCluster fd_datacenter vm_host_info

    nodes_list=$(oc get nodes --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/${node_type} -o json | jq -r '.items[].metadata.name')
    for node in ${nodes_list}; do
	# shellcheck disable=SC2207
	label_info=($(oc get node ${node} --show-labels --no-headers | awk -F, '{print $(NF-1),$NF}'))
        node_region=$(echo ${label_info[0]} | awk -F= '{print $2}')
        node_zone=$(echo ${label_info[1]} | awk -F= '{print $2}')
        echo "checking labels on node ${node}, label region: ${node_region}, label zone: ${node_zone}"
        fd_region=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).region")
        fd_name=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).name")
        fd_datacenter=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).topology.datacenter")
	[[ -z "${fd_datacenter}" ]] && fd_datacenter=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.datacenter")
	fd_folder=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).topology.folder")
	[[ -z "${fd_folder}" ]] && fd_folder="/${fd_datacenter}/vm/${infra_id}"
	fd_computeCluster=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(zone==${node_zone}).topology.computeCluster")
        vm_host_info=$(govc vm.info ${fd_folder}/${node} | grep 'Host' | awk -F ":" '{print $2}' | xargs)

	if [[ -z ${fd_region} ]]; then
            echo "ERROR: label zone is ${node_zone}, but not found any failureDomain region setting with this zone in install-config!"
            check_result=1
	fi
	if [[ -n "$(govc ls ${fd_folder}/${node})" ]];then
            echo "INFO: ${node} is created under correct path: ${fd_folder}"

	else
            check_result=1
	    echo "ERROR: not found ${node} under path:${fd_folder}"
        fi
        if [[ -n "$(govc ls ${fd_computeCluster}/${vm_host_info}/${node})" ]];then
            echo "INFO: ${node} is created under correct host:${fd_computeCluster}/${vm_host_info}"
        else
	    check_result=1
	    echo "ERROR: ${node} is created under incorrect host"
	fi

        # shellcheck disable=SC2076
        if [[ "${fd_region}" == "${node_region}" ]] && [[ " ${node_fd_list} " =~ " ${fd_name} " ]]; then
            echo "INFO: node reside in failureDomain ${fd_name}, with region ${node_region}, zone ${node_zone}"
        else
	    check_result=1
            echo "ERROR: node region is not found in failureDomain on ${node_type} node setting in install-config!"
        fi
    done
    return ${check_result}
}


default_fd_list=$(yq-go r ${INSTALL_CONFIG} 'platform.vsphere.defaultMachinePlatform.zones[*]' | xargs)
master_fd_list=$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.vsphere.zones[*]' | xargs)
[[ -z "${master_fd_list}" ]] && master_fd_list=${default_fd_list}
if [[ -z "${master_fd_list}" ]]; then
    echo "No zone setting on controlPlane node in install-config, node will be created in any failureDomain"
    master_fd_list="${zones_name_from_config[*]}"
fi
echo "the zones setting for controlPlane node : ${master_fd_list}"

worker_fd_list=$(yq-go r ${INSTALL_CONFIG} 'compute[*].platform.vsphere.zones[*]' | xargs)
[[ -z "${worker_fd_list}" ]] && worker_fd_list=${default_fd_list}
if [[ -z "${worker_fd_list}" ]]; then
    echo "No failureDomain setting on compute node in install-config, node will be created in any failureDomain"
    worker_fd_list="${zones_name_from_config[*]}"
fi
echo "the zones setting for compute node :${worker_fd_list}"

echo -e "\nChecking labels on each node..."
check_label_vmcluster "master" "${master_fd_list}" || check_result=1
check_label_vmcluster "worker" "${worker_fd_list}" || check_result=1

exit ${check_result}
