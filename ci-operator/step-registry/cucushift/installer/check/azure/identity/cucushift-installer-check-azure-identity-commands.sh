#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

function check_vm_identity()
{

    local node_type=$1 expected_identity=$2 node_filter=${3:-} nodes_list ret=0
    nodes_list=$(oc get nodes --selector ${node_filter}node-role.kubernetes.io/${node_type} -o json | jq -r '.items[].metadata.name')
    expected_identity=${expected_identity//resourcegroups/resourceGroups}
    if [[ ${node_type} == "worker" ]]; then
        expected_identity=$(echo ${expected_identity} | awk '{print $1}')
    fi
    for node in ${nodes_list}; do
        echo "checking ${node_type} node: ${node}..."
        node_identity_id=$(az vm show -g "${RESOURCE_GROUP}" -n "${node}" -otsv --query "identity.userAssignedIdentities.keys(@)" -otsv)
        node_identity_id=${node_identity_id//resourcegroups/resourceGroups}
        for id in ${expected_identity}; do
            if [[ "${node_identity_id}" =~ ${id} ]]; then
                echo "INFO: expected identity ${id} is attached to node!"
            else
                echo "ERROR: expected identity: ${id} is not attached to node, unexpected!"
                echo "node identity list: ${node_identity_id}"
                ret=1
            fi
        done
    done

    return $ret
}

function check_machine_managedIdentity()
{

    local machine_type=$1 expected_identity=$2 expected_identity_name=${3:-} machine ret=0
    machine_list=$(oc get machines.machine.openshift.io -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=${machine_type} -ojson | jq -r '.items[].metadata.name')
    for machine in ${machine_list}; do
        echo "checking machine ${machine}..."
        machine_managed_identity=$(oc get machines.machine.openshift.io -n openshift-machine-api ${machine} -ojson | jq -r '.spec.providerSpec.value.managedIdentity')
        if [[ "${machine_managed_identity}" == "${expected_identity}" ]] || [[ "${machine_managed_identity}" == "${expected_identity_name}" ]]; then
            echo "INFO: expected identity ${expected_identity} is configured in machine spec."
        else
            echo "ERROR: expected identity 4.18- with name ${expected_identity_name} or 4.19+ with id ${expected_identity} is not configured in machine spec, unexpected!"
            echo "Identity in machine spec: ${machine_managed_identity}"
            ret=1
        fi
    done
    return $ret
}

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

check_result=0
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
cluster_identity_id=$(az identity list -g "${RESOURCE_GROUP}" --query "[].id" -otsv)
cluster_identity_name=$(az identity list -g "${RESOURCE_GROUP}" --query "[].name" -otsv)
ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if (( ${ocp_minor_version} < 19 )) && [[ -z "${cluster_identity_id}" ]]; then
    echo "On 4.18 and previous version, user-assigned identity is created by installer, but not find, exit..."
    exit 1
elif (( ${ocp_minor_version} >= 19 )) && [[ -n "${cluster_identity_id}" ]]; then
    echo "On 4.19+, installer does not create user-assigned identity any more, but find it ${cluster_identity_id}, exit..."
    exit 1
fi

control_plane_identity_id="${cluster_identity_id}"
compute_identity_id="${cluster_identity_id}"
identity_type_default=$(yq-go r ${INSTALL_CONFIG} 'platform.azure.defaultMachinePlatform.identity.type')
if [[ "${identity_type_default}" == "UserAssigned" ]]; then
    end_number=$((AZURE_USER_ASSIGNED_IDENTITY_NUMBER - 1))
    control_plane_identity_id=""
    compute_identity_id=""
    for num in $(seq 0 ${end_number}); do
        subscrption=$(yq-go r ${INSTALL_CONFIG} "platform.azure.defaultMachinePlatform.identity.userAssignedIdentities[$num].subscription")
        name=$(yq-go r ${INSTALL_CONFIG} "platform.azure.defaultMachinePlatform.identity.userAssignedIdentities[$num].name")
        rg=$(yq-go r ${INSTALL_CONFIG} "platform.azure.defaultMachinePlatform.identity.userAssignedIdentities[$num].resourceGroup")
        control_plane_identity_id+=" /subscriptions/${subscrption}/resourceGroups/${rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${name}"
        compute_identity_id+=" /subscriptions/${subscrption}/resourceGroups/${rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${name}"
    done
fi
identity_type_control_plane=$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.identity.type')
if [[ "${identity_type_control_plane}" == "UserAssigned" ]]; then
    end_number=$((AZURE_USER_ASSIGNED_IDENTITY_NUMBER - 1))
    control_plane_identity_id=""
    for num in $(seq 0 ${end_number}); do
        subscrption=$(yq-go r ${INSTALL_CONFIG} "controlPlane.platform.azure.identity.userAssignedIdentities[$num].subscription")
        name=$(yq-go r ${INSTALL_CONFIG} "controlPlane.platform.azure.identity.userAssignedIdentities[$num].name")
        rg=$(yq-go r ${INSTALL_CONFIG} "controlPlane.platform.azure.identity.userAssignedIdentities[$num].resourceGroup")
        control_plane_identity_id+=" /subscriptions/${subscrption}/resourceGroups/${rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${name}"
    done
fi
identity_type_compute=$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.identity.type')
if [[ "${identity_type_compute}" == "UserAssigned" ]]; then
    end_number=$((AZURE_USER_ASSIGNED_IDENTITY_NUMBER - 1))
    compute_identity_id=""
    for num in $(seq 0 ${end_number}); do
        subscrption=$(yq-go r ${INSTALL_CONFIG} "compute[0].platform.azure.identity.userAssignedIdentities[$num].subscription")
        name=$(yq-go r ${INSTALL_CONFIG} "compute[0].platform.azure.identity.userAssignedIdentities[$num].name")
        rg=$(yq-go r ${INSTALL_CONFIG} "compute[0].platform.azure.identity.userAssignedIdentities[$num].resourceGroup")
        compute_identity_id+=" /subscriptions/${subscrption}/resourceGroups/${rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${name}"
    done
fi

echo "control_plane_identity_id: ${control_plane_identity_id}"
echo "compute_identity_id: ${compute_identity_id}"

if [[ -z "${control_plane_identity_id}" ]] && [[ -z "${compute_identity_id}" ]] && (( ${ocp_minor_version} >= 19 )); then
    echo "No identity is specified in install-config and no user-assigned identity is created by default on 4.19+, skip the check..."
    exit 0
fi

# Check that specified identity should be attached on each node
echo "-------------Check that identity is attached on each node-------------"
ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
node_filter=""
if (( ${ocp_minor_version} < 19 )); then
    # No rhel worker is provisioned on 4.19+
    node_filter="node.openshift.io/os_id=rhcos,"
fi
check_vm_identity "master" "${control_plane_identity_id}" "${node_filter}" || check_result=1
check_vm_identity "worker" "${compute_identity_id}" "${node_filter}" || check_result=1

#Currently, only one identity is attached to work nodes and configured in object machine/machineset/controlplanmachineset in cluster
control_plane_identity_id=$(echo "${control_plane_identity_id}" | awk '{print $1}')
compute_identity_id=$(echo "${compute_identity_id}" | awk '{print $1}')

# machine
echo "-------------Check identity in machine spec-------------"
check_machine_managedIdentity "master" "${control_plane_identity_id}" "${cluster_identity_name}"|| check_result=1
check_machine_managedIdentity "worker" "${compute_identity_id}" "${cluster_identity_name}" || check_result=1

# machinset
echo "-------------Check identity in machineset spec-------------"
machineset_list=$(oc get machineset.m -n openshift-machine-api -ojson | jq -r '.items[].metadata.name')
for machineset in ${machineset_list}; do
    echo "checking machineset ${machineset}..."
    machineset_identity=$(oc get machineset.m -n openshift-machine-api ${machineset} -ojson | jq -r '.spec.template.spec.providerSpec.value.managedIdentity')
    if [[ "${machineset_identity}" == "${compute_identity_id}" ]] || [[ "${machineset_identity}" == "${cluster_identity_name}" ]]; then
        echo "INFO: expected identity is configured in machineset spec!"
    else
        echo "ERROR: expected identity 4.18- with name ${cluster_identity_name} or 4.19+ with id ${compute_identity_id} is not configured in machineset spec, unexpected!"
        echo "identity in machineset spec: ${machineset_identity}"
        check_result=1
    fi
done

# controlplanemachineset
echo "-------------Check identity in controlplanemachineset spec-------------"
cpms_identity=$(oc get controlplanemachineset cluster -n openshift-machine-api -ojson | jq -r '.spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.managedIdentity')
echo "checking controlplanemachineset cluster..."
if [[ "${cpms_identity}" == "${control_plane_identity_id}" ]] || [[ "${cpms_identity}" == "${cluster_identity_name}" ]]; then
    echo "INFO: expected identity is configured in cpms spec!"
else
    echo "ERROR: expected identity 4.18- with name ${cluster_identity_name} or 4.19+ with id ${control_plane_identity_id} ${cluster_identity_name} is not configured in cpms spec, unexpected!"
    echo "identity in cpms spec: ${cpms_identity}"
    check_result=1
fi

exit ${check_result}
