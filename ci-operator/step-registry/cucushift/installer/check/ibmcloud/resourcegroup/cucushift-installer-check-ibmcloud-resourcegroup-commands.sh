#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output
    region="${LEASED_RESOURCE}"
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    echo "Try to login..."
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

#OCP-60816 - [IPI-on-IBMCloud] install cluster under BYON with a different resource group
function getResources() {
    "${IBMCLOUD_CLI}" resource service-instances --type all --output JSON | jq -r '.[]|.name+" "+.resource_id' | sort
}

function checkResourcesInVPC() {
    local preResourceFile resource_group curResourceFile cmpRst
    resource_group=$1
    preResourceFile=$2
    "${IBMCLOUD_CLI}" target -g ${resource_group}
    curResourceFile=$(mktemp)
    getResources > ${curResourceFile}
    echo "diff ${curResourceFile} ${preResourceFile} ..."
    cmpRst=$(diff ${curResourceFile} ${preResourceFile})
    if [ -n "$cmpRst" ]; then
        echo "ERROR: resources differ: ${cmpRst}"
        return 1
    else
        echo "checkResourcesinVPC PASS"  
        return 0
    fi
}

provisioned_resource_group=$(cat "${SHARED_DIR}/ibmcloud_resource_group")

check_result=0
ibmcloud_login

# checking vpc resource group
preResourceFile="${SHARED_DIR}/vpc_resources"
if [ -f "${preResourceFile}" ]; then
    vpc_resource_group="${provisioned_resource_group}"
    checkResourcesInVPC ${vpc_resource_group} "${preResourceFile}" || check_result=1
fi

echo "CREATE_CLUSTER_RESOURCE_GROUP: ${CREATE_CLUSTER_RESOURCE_GROUP}; provisioned_resource_group: ${provisioned_resource_group}"

# check the cluster_resource_group.
if [ "${CREATE_CLUSTER_RESOURCE_GROUP}" == "yes" ]; then           
    cluster_resource_group=$(cat "${SHARED_DIR}/ibmcloud_cluster_resource_group")
    if [[ "${provisioned_resource_group}" == "${cluster_resource_group}" ]]; then        
        echo "ERROR: vpc and cluster use the same resource group ${cluster_resource_group} when CREATE_CLUSTER_RESOURCE_GROUP is set!"
        check_result=1
    fi
else
    cluster_resource_group="${provisioned_resource_group}"
fi

cluster_resource_group_from_installer=$(jq -r .ibmcloud.resourceGroupName ${SHARED_DIR}/metadata.json)
if [[ "${cluster_resource_group_from_installer}" != "${cluster_resource_group}" ]]; then
    echo "ERROR: provisioned cluster resource group does not match with the one in installer metadata json !"
    check_result=1
fi

#check the cluster in the cluster resource group
if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

nodes_count=$(oc get nodes --no-headers | wc -l)
insCount=$(${IBMCLOUD_CLI} is ins --resource-group-name ${cluster_resource_group} --output JSON | jq '.|length')
if [ "${nodes_count}" -ne "${insCount}" ]; then
    echo "ERROR: cluster nodes: $nodes_count; instances in the cluster resource group: $insCount should be same"
    check_result=1
fi
   
exit $check_result