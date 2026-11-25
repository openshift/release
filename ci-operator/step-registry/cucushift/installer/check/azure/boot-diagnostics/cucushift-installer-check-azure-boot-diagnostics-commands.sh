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

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}


function check_boot_diagnostics_enabled() {

    local node_list=$1 diagnostics_type=${2:-} expected_storage_uri=${3:-} expected_diagnostics diagnostics ret=0

    if [[ "${diagnostics_type}" == "Managed" ]] || [[ "${diagnostics_type}" == "UserManaged" ]]; then
        expected_diagnostics="true"
    else
        expected_diagnostics="false"
    fi

    for node in ${node_list}; do
        diagnostics=$(az vm show --name ${node} -g ${RESOURCE_GROUP} --query 'diagnosticsProfile.bootDiagnostics.enabled' -otsv)
        if [[ "${diagnostics}" == "${expected_diagnostics}" ]] || ([[ -z "${diagnostics}" ]] && [[ "${expected_diagnostics}" == "false" ]]); then
            echo "INFO: bootDiagnostics.enabled check pass on node ${node}!"
        else
            echo "ERROR: bootDiagnostics.enabled check failed on node ${node}!"
            run_command "az vm show --name ${node} -g ${RESOURCE_GROUP} --query 'diagnosticsProfile.bootDiagnostics'"
            ret=1
        fi
        if [[ -n "${expected_storage_uri}" ]]; then
            storage_uri=$(az vm show --name ${node} -g ${RESOURCE_GROUP} --query 'diagnosticsProfile.bootDiagnostics.storageUri' -otsv)
            if [[ "${storage_uri}" == "${expected_storage_uri}" ]]; then
                echo "INFO: bootDiagnostics.storageUri check passed on node ${node}!"
            else
                echo "ERROR: bootDiagnostics.storageUri check failed on node ${node}!"
                run_command "az vm show --name ${node} -g ${RESOURCE_GROUP} --query 'diagnosticsProfile.bootDiagnostics'"
                ret=1
            fi
        fi
    done

    return $ret
}

function check_console_uri() {

    local node_list=$1 ret=0 console_screenshot_blob serial_console_log_blob

    for node in ${node_list}; do
        if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
            # Azure Stack Hub (2019-03-01-hybrid profile) only has get-boot-log, not get-boot-log-uris
            echo "Checking boot diagnostics log on Azure Stack Hub node ${node}..."
            boot_log=$(az vm boot-diagnostics get-boot-log --name ${node} -g ${RESOURCE_GROUP} 2>&1)
            exit_code=$?

            if [[ $exit_code -eq 0 ]]; then
                echo "INFO: boot diagnostics accessible on node ${node}"
            elif echo "${boot_log}" | grep -q "BlobNotFound"; then
                # BlobNotFound is expected for VMs that haven't generated logs yet (healthy VMs)
                echo "INFO: boot diagnostics configured on node ${node} (blob not yet generated - this is normal for healthy VMs)"
                echo "Verifying boot diagnostics by checking for screenshot blob..."
                vm_id=$(az vm show --name ${node} --resource-group ${RESOURCE_GROUP} --query "vmId" -o tsv 2>&1)
                if [[ $? -ne 0 ]]; then
                    echo "ERROR: failed to get VM ID for node ${node}"
                    echo "Error: ${vm_id}"
                    ret=1
                    continue
                fi

                storage_uri=$(az vm show --name ${node} --resource-group ${RESOURCE_GROUP} --query "diagnosticsProfile.bootDiagnostics.storageUri" -o tsv 2>&1)
                if [[ $? -ne 0 ]] || [[ -z "${storage_uri}" ]]; then
                    echo "ERROR: failed to get storage URI for node ${node}"
                    echo "Error: ${storage_uri}"
                    ret=1
                    continue
                fi

                # Extract storage account name from URI (e.g., https://storageaccount.blob.example.com -> storageaccount)
                storage_account=$(echo "${storage_uri}" | sed 's|https://||' | sed 's|\..*||')

                # Container name pattern: bootdiagnostics-{first 9 chars of VM name without dashes}-{VM_ID}
                vm_name_normalized=$(echo "${node}" | tr -d '-')
                container_name="bootdiagnostics-${vm_name_normalized:0:9}-${vm_id}"

                echo "Checking container: ${container_name} in storage account: ${storage_account}"

                # List blobs and check for screenshot.bmp
                blob_list=$(az storage blob list --account-name "${storage_account}" --container-name "${container_name}" --query "[?ends_with(name, '.screenshot.bmp')].name" -o tsv 2>&1)
                blob_exit_code=$?

                if [[ $blob_exit_code -eq 0 ]] && [[ -n "${blob_list}" ]]; then
                    echo "INFO: boot diagnostics screenshot blob found for node ${node}: ${blob_list}"
                else
                    echo "ERROR: boot diagnostics screenshot blob not found for node ${node}"
                    echo "Storage account: ${storage_account}, Container: ${container_name}"
                    if [[ $blob_exit_code -ne 0 ]]; then
                        echo "Error output: ${blob_list}"
                    fi
                    ret=1
                fi
            else
                echo "ERROR: failed to get boot diagnostics log on node ${node}!"
                echo "Error output: ${boot_log}"
                ret=1
            fi
        else
            console_screenshot_blob=$(az vm boot-diagnostics get-boot-log-uris --name ${node} -g ${RESOURCE_GROUP} --query consoleScreenshotBlobUri -otsv)
            serial_console_log_blob=$(az vm boot-diagnostics get-boot-log-uris --name ${node} -g ${RESOURCE_GROUP} --query serialConsoleLogBlobUri -otsv)
            if [[ -z "${console_screenshot_blob}" ]] || [[ -z "${serial_console_log_blob}" ]]; then
                echo "ERROR: failed to get console screenshot blob uri or serial console log uri on node ${node}!"
                run_command "az vm boot-diagnostics get-boot-log-uris --name ${node} -g ${RESOURCE_GROUP}"
                ret=1
            else
                echo "INFO: console blob uri check passed on node ${node}"
            fi
	fi
    done

    return $ret
}

function check_machines_in_cluster() {

    local node_type=$1 node_list=$2 expected_boot_diagnostics_type=$3 expected_storage_uri=${4:-} ret=0 diagnostics_type storage_uri 

    if [[ "${expected_boot_diagnostics_type}" == "UserManaged" ]]; then
        expected_boot_diagnostics_type="CustomerManaged"
    elif [[ "${expected_boot_diagnostics_type}" == "Managed" ]]; then
        expected_boot_diagnostics_type="AzureManaged"
    fi

    for node in ${node_list}; do
        echo "Checking machine ${node}..."
        run_command "oc get machines.machine.openshift.io -n openshift-machine-api ${node} -ojson | jq -r '.spec.providerSpec.value.diagnostics'"
        diagnostics_type=$(oc get machines.machine.openshift.io -n openshift-machine-api ${node} -ojson | jq -r '.spec.providerSpec.value.diagnostics.boot.storageAccountType')
        if [[ "${expected_boot_diagnostics_type}" == "${diagnostics_type}" ]]; then
            echo "INFO: storageAccountType on machine ${node} check passed!"
        else
            echo "ERROR: storageAccountType on machine ${node} check failed!"
            ret=1
        fi
        if [[ "${expected_boot_diagnostics_type}" == "CustomerManaged" ]]; then
            storage_uri=$(oc get machines.machine.openshift.io -n openshift-machine-api ${node} -ojson | jq -r '.spec.providerSpec.value.diagnostics.boot.customerManaged.storageAccountURI')
            if [[ "${expected_storage_uri}" == "${storage_uri}" ]]; then
                echo "INFO: storageAccountURI on machine ${node} check passed!"
            else
                echo "ERROR: storageAccountURI on machine ${node} check failed!"
                ret=1
            fi
        fi
    done

    if [[ "${node_type}" == "master" ]]; then
        echo "Checking controlplanemachineset..."
        run_command "oc get controlplanemachineset -n openshift-machine-api cluster -ojson | jq -r '.spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.diagnostics'"
        cpms_diagnostics_type=$(oc get controlplanemachineset -n openshift-machine-api cluster -ojson | jq -r '.spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.diagnostics.boot.storageAccountType')
        if [[ "${cpms_diagnostics_type}" == "${expected_boot_diagnostics_type}" ]]; then
            echo "INFO: storageAccountType check passed in cpms spec!"
        else
            echo "ERROR: storageAccountType check failed in cpms spec!"
            ret=1
        fi
        if [[ "${expected_boot_diagnostics_type}" == "CustomerManaged" ]]; then
            cpms_storage_uri=$(oc get controlplanemachineset -n openshift-machine-api cluster -ojson | jq -r '.spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.diagnostics.boot.customerManaged.storageAccountURI')
            if [[ "${expected_storage_uri}" == "${cpms_storage_uri}" ]]; then
                echo "INFO: storageAccountURI check passed in cpms spec!"
            else
                echo "ERROR: storageAccountURI check failed in cpms spec!"
                ret=1
            fi
        fi
    fi


    if [[ "${node_type}" == "worker" ]]; then
        echo "Checking machineset..."
        machineset_name=$(oc get machinesets.machine.openshift.io -n openshift-machine-api -ojson | jq -r '.items[].metadata.name' | head -1)
        run_command "oc get machinesets.machine.openshift.io -n openshift-machine-api ${machineset_name} -ojson | jq -r '.spec.template.spec.providerSpec.value.diagnostics'"
        machineset_diagnostics_type=$(oc get machinesets.machine.openshift.io -n openshift-machine-api ${machineset_name} -ojson | jq -r '.spec.template.spec.providerSpec.value.diagnostics.boot.storageAccountType')
        if [[ "${machineset_diagnostics_type}" == "${expected_boot_diagnostics_type}" ]]; then
            echo "INFO: storageAccountType check passed in machineset ${machineset_name} spec!"
        else
            echo "ERROR: storageAccountType check failed in machineset ${machineset_name} spec!"
            ret=1
        fi
        if [[ "${expected_boot_diagnostics_type}" == "CustomerManaged" ]]; then
            machineset_storage_uri=$(oc get machinesets.machine.openshift.io -n openshift-machine-api ${machineset_name} -ojson | jq -r '.spec.template.spec.providerSpec.value.diagnostics.boot.customerManaged.storageAccountURI')
            if [[ "${expected_storage_uri}" == "${machineset_storage_uri}" ]]; then
                echo "INFO: storageAccountURI check passed in machineset ${machineset_name} spec!"
            else
                echo "ERROR: storageAccountURI check failed in machineset ${machineset_name} spec!"
                ret=1
            fi
        fi
    fi
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

default_diagnostics_type=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.defaultMachinePlatform.bootDiagnostics.type')
master_diagnostics_type=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.bootDiagnostics.type')
worker_diagnostics_type=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.bootDiagnostics.type')
cloud_name=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.cloudName')

# default boot diagnostics is enabled as Managed type on control plane nodes
expected_master_diag_type="Managed"
# default boot diagnostics is disabled on compute nodes
expected_worker_diag_type=""
master_sa_name=""
master_sa_rg=""
worker_sa_name=""
worker_sa_rg=""
if [[ -n "${default_diagnostics_type}" ]]; then
    expected_master_diag_type="${default_diagnostics_type}"
    expected_worker_diag_type="${default_diagnostics_type}"
    if [[ "${default_diagnostics_type}" == "UserManaged" ]]; then
        master_sa_name=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.defaultMachinePlatform.bootDiagnostics.storageAccountName')
        worker_sa_name=${master_sa_name}
        master_sa_rg=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.defaultMachinePlatform.bootDiagnostics.resourceGroup')
        worker_sa_rg="${master_sa_rg}"
    fi
fi

if [[ -n "${master_diagnostics_type}" ]]; then
    expected_master_diag_type="${master_diagnostics_type}"
    if [[ "${master_diagnostics_type}" == "UserManaged" ]]; then
        master_sa_name=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.bootDiagnostics.storageAccountName')
        master_sa_rg=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.bootDiagnostics.resourceGroup')
    else
        master_sa_name=""
    fi
fi

if [[ -n "${worker_diagnostics_type}" ]]; then
    expected_worker_diag_type="${worker_diagnostics_type}"
    if [[ "${worker_diagnostics_type}" == "UserManaged" ]]; then
        worker_sa_name=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.bootDiagnostics.storageAccountName')
        worker_sa_rg=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.bootDiagnostics.resourceGroup')
    else
        worker_sa_name=""
    fi
fi

check_result=0

# checking on master nodes
master_nodes_list=$(oc get nodes --selector node-role.kubernetes.io/master -o json | jq -r '.items[].metadata.name')
# If expected_master_diag_type is not set, managed boot diagnostics is enabled on master nodes by default.
if [[ -z "${expected_master_diag_type}" ]]; then
    expected_master_diag_type="Managed"
fi
if [[ -n "${master_sa_name}" ]]; then
    master_storage_uri=$(az storage account show -n ${master_sa_name} -g ${master_sa_rg} --query primaryEndpoints.blob -otsv)
    master_storage_uri=${master_storage_uri::-1}
else
    master_storage_uri=""
fi

echo "Expected master diagnostics type: ${expected_master_diag_type}"
echo "Expected master storage uri: ${master_storage_uri}"
echo "Checking options setting on master machines..."
check_boot_diagnostics_enabled "${master_nodes_list}" "${expected_master_diag_type}" "${master_storage_uri}" || check_result=1
if [[ "${expected_master_diag_type}" != "Disabled" ]]; then
    echo "Checking master node conosle uri..."
    check_console_uri "${master_nodes_list}" || check_result=1
    echo "Checking machine/controlplanemachineset in cluster ..."
    check_machines_in_cluster "master" "${master_nodes_list}" "${expected_master_diag_type}" "${master_storage_uri}" || check_result=1
fi

# Checking on worker nodes
worker_nodes_list=$(oc get nodes --selector node-role.kubernetes.io/worker -o json | jq -r '.items[].metadata.name')
# If expected_worker_diag_type is not set, boot diagnostics is disabled on worker nodes by default.
if [[ -z "${expected_worker_diag_type}" ]]; then
    expected_worker_diag_type="Disabled"
fi
if [[ -n "${worker_sa_name}" ]]; then
    worker_storage_uri=$(az storage account show -n ${worker_sa_name} -g ${worker_sa_rg} --query primaryEndpoints.blob -otsv)
    worker_storage_uri=${worker_storage_uri::-1}
else
    worker_storage_uri=""
fi

echo "Expected worker diagnostics type: ${expected_worker_diag_type}"
echo "Expected worker storage uri: ${worker_storage_uri}"
echo "Checking options setting on worker machines..."
check_boot_diagnostics_enabled "${worker_nodes_list}" "${expected_worker_diag_type}" "${worker_storage_uri}" || check_result=1
if [[ "${expected_worker_diag_type}" != "Disabled" ]]; then
    echo "Checking worker node conosle uri..."
    check_console_uri "${worker_nodes_list}" || check_result=1
    echo "Checking machine/machineset in cluster ..."
    check_machines_in_cluster "worker" "${worker_nodes_list}" "${expected_worker_diag_type}" "${worker_storage_uri}" || check_result=1
fi

exit ${check_result}
