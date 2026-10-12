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


function multi_disk_check()
{

    local expected_settings_json=$1 node_json=$2 ret=0
    local node_disk_size node_disk_caching_type node_disk_lun_id node_storage_account_type node_des node_security_encryption_type

    declare -A expected_settings
    while IFS='=' read -r key value; do
        expected_settings["$key"]="$value"
    done < <(echo "${expected_settings_json}" | jq -r 'to_entries | .[] | .key + "=" + .value')

    node_disk_size=$(jq -r '.[].diskSizeGb' ${node_json})
    if [[ "${node_disk_size}" == "${expected_settings[disk_size]}" ]]; then
        echo "INFO: checking disk size of data disk on node passed!"
    else
        echo "ERROR: checking disk size of data disk on node failed! real value: ${node_disk_size}, expected value: ${expected_settings[disk_size]}"
        ret=1
    fi

    node_disk_caching_type=$(jq -r '.[].caching'  ${node_json})
    # The default caching type is "ReadWrite" on master nodes, "None" on worker nodes.
    if [[ "${node_disk_caching_type}" == "${expected_settings[caching_type]:-ReadWrite}" ]] || [[ "${node_disk_caching_type}" == "${expected_settings[caching_type]:-None}" ]]; then
        echo "INFO: checking disk caching type of data disk on node passed!"
    else
        echo "ERROR: checking disk caching type of data disk on node failed! real value: ${node_disk_caching_type}, expected value: ${expected_settings[caching_type]}"
        ret=1
    fi

    node_disk_lun_id=$(jq -r '.[].lun' ${node_json})
    if [[ "${node_disk_lun_id}" == "${expected_settings[lun_id]}" ]]; then
        echo "INFO: checking disk lun id of data disk on node passed!"
    else
        echo "ERROR: checking disk lun id of data disk on node failed! real vaule: ${node_disk_lun_id}, expected value: ${expected_settings[lun_id]}"
        ret=1
    fi

    node_storage_account_type=$(jq -r '.[].managedDisk.storageAccountType' ${node_json})
    if [[ "${node_storage_account_type}" == "${expected_settings[storage_account_type]:-Premium_LRS}" ]]; then
        echo "INFO: checking storage account type of data disk on node passed!"
    else
        echo "ERROR: checking storage account type of data disk on node failed! real value: ${node_storage_account_type}, expected value: ${expected_settings[storage_account_type]}"
        ret=1
    fi

    if [[ -n "${expected_settings[disk_encyption_set]}" ]]; then
        node_des=$(jq -r '.[].managedDisk.diskEncryptionSet' ${node_json})
        if [[ "${node_des}" == "${expected_settings[disk_encyption_set]}" ]]; then
            echo "INFO: checking disk encryption set of data disk on node passed!"
        else
            echo "ERROR: checking disk encrypiton set of data disk on node failed! real value: ${node_des}, expected value: ${expected_settings[disk_encyption_set]}"
            ret=1
        fi
    fi


    if [[ -n "${expected_settings[security_encryption_type]}" ]]; then
        node_security_encryption_type=$(jq -r '.[].managedDisk.securityProfile.securityEncryptionType' ${node_json})
        if [[ "${node_security_encryption_type}" == "${expected_settings[security_encryption_type]}" ]]; then
            echo "INFO: checking disk security encryption type of data disk on node passed!"
        else
            echo "ERRPR: checking disk security encryption type of data disk on node failed! real value: ${node_security_encryption_type}, expected value: ${expected_settings[security_encryption_type]}"
            ret=1
        fi
    fi

    if [[ -n "${expected_settings[security_profile_des]}" ]]; then
        node_security_profile_des=$(jq -r '.[].managedDisk.securityProfile.diskEncryptionSet' ${node_json})
        if [[ "${node_security_profile_des}" == "${expected_settings[security_profile_des]}" ]]; then
            echo "INFO: checking disk ecryption set under security profile of data disk on node passed!"
        else
            echo "ERROR: checking disk encryption set under security profile of data disk on node failed! real value: ${node_security_profile_des}, expected value: ${expected_settings[security_profile_des]}"
            ret=1
        fi
    fi

    return $ret
}

function machine_pool_check(){
    local expected_settings_json=$1 machine_pool_spec=$2 ret=0
    local spec_disk_size spec_disk_caching_type spec_disk_lun_id spec_storage_account_type spec_des spec_security_encryption_type

    declare -A expected_settings
    while IFS='=' read -r key value; do
        expected_settings["$key"]="$value"
    done < <(echo "${expected_settings_json}" | jq -r 'to_entries | .[] | .key + "=" + .value')

    spec_disk_size=$(jq -r '.diskSizeGB' ${machine_pool_spec})
    if [[ "${spec_disk_size}" == "${expected_settings[disk_size]}" ]]; then
        echo "INFO: checking disk size in spec passed!"
    else
        echo "ERROR: checking disk size in spec failed! real value: ${spec_disk_size}, expected value: ${expected_settings[disk_size]}"
        ret=1
    fi

    spec_disk_caching_type=$(jq -r '.cachingType' ${machine_pool_spec})
    if [[ "${spec_disk_caching_type}" == "${expected_settings[caching_type]:-null}" ]]; then
        echo "INFO: checking disk caching type in spec on node passed!"
    else
        echo "ERROR: checking disk caching type in spec on node failed! real value: ${spec_disk_caching_type}, expected value: ${expected_settings[caching_type]}"
        ret=1
    fi

    spec_disk_lun_id=$(jq -r '.lun' ${machine_pool_spec})
    if [[ "${spec_disk_lun_id}" == "${expected_settings[lun_id]}" ]]; then
        echo "INFO: checking disk lun id in spec on node passed!"
    else
        echo "ERROR: checking disk lun id spec on node failed! real vaule: ${spec_disk_lun_id}, expected value: ${expected_settings[lun_id]}"
        ret=1
    fi

    spec_storage_account_type=$(jq -r '.managedDisk.storageAccountType' ${machine_pool_spec})
    if [[ "${spec_storage_account_type}" == "${expected_settings[storage_account_type]}" ]]; then
        echo "INFO: checking storage account type in spec on node passed!"
    else
        echo "ERROR: checking storage account type in spec on node failed! real value: ${spec_storage_account_type}, expected value: ${expected_settings[storage_account_type]}"
        ret=1
    fi

    if [[ -n "${expected_settings[disk_encyption_set]}" ]]; then
        spec_des=$(jq -r '.managedDisk.diskEncryptionSet' ${machine_pool_spec})
        if [[ "${spec_des}" == "${expected_settings[disk_encyption_set]}" ]]; then
            echo "INFO: checking disk encryption set in spec on node passed!"
        else
            echo "ERROR: checking disk encrypiton set in spec on node failed! real value: ${spec_des}, expected value: ${expected_settings[disk_encyption_set]}"
            ret=1
        fi
    fi


    if [[ -n "${expected_settings[security_encryption_type]}" ]]; then
        spec_security_encryption_type=$(jq -r '.managedDisk.securityProfile.securityEncryptionType' ${machine_pool_spec})
        if [[ "${spec_security_encryption_type}" == "${expected_settings[security_encryption_type]}" ]]; then
            echo "INFO: checking disk security encryption type in spec on node passed!"
        else
            echo "ERRPR: checking disk security encryption type in spec on node failed! real value: ${spec_security_encryption_type}, expected value: ${expected_settings[security_encryption_type]}"
            ret=1
        fi
    fi

    if [[ -n "${expected_settings[security_profile_des]}" ]]; then
        spec_security_profile_des=$(jq -r '.managedDisk.securityProfile.diskEncryptionSet' ${machine_pool_spec})
        if [[ "${spec_security_profile_des}" == "${expected_settings[security_profile_des]}" ]]; then
            echo "INFO: checking disk ecryption set under security profile of data disk on node passed!"
        else
            echo "ERROR: checking disk encryption set under security profile of data disk on node failed! real value: ${spec_security_profile_des}, expected value: ${expected_settings[security_profile_des]}"
            ret=1
        fi
    fi

    return $ret
}


INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

check_result=0

cp_multi_disk_type="$(yq-go r ${INSTALL_CONFIG} 'controlPlane.diskSetup[0].type')"
cp_multi_disk="{}"
if [[ -n "${cp_multi_disk_type}" ]]; then
    cp_multi_disk_name_suffix="$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].nameSuffix')"
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"caching_type\":\"$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].cachingType')\"}")
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"disk_size\":\"$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].diskSizeGB')\"}")
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"lun_id\":\"$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].lun')\"}")
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"storage_account_type\":\"$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].managedDisk.storageAccountType')\"}")
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"disk_encyption_set\":\"$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].managedDisk.diskEncryptionSet.id')\"}")
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"security_encryption_type\":\"$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].managedDisk.securityProfile.securityEncryptionType')\"}")
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"security_profile_des\":\"$(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.dataDisks[0].managedDisk.securityProfile.diskEncryptionSet.id')\"}")
    if [[ "${cp_multi_disk_type}" == "user-defined" ]]; then
        cp_mount_path="$(yq-go r ${INSTALL_CONFIG} 'controlPlane.diskSetup[0].userDefined.mountPath')"
    elif [[ "${cp_multi_disk_type}" == "etcd" ]]; then
        cp_mount_path="/var/lib/etcd"
    elif [[ "${cp_multi_disk_type}" == "swap" ]]; then
        cp_mount_path="swap"
    fi
    cp_multi_disk=$(echo "${cp_multi_disk}" | jq -c -S ". +={\"mount_path\":\"${cp_mount_path}\"}")

    echo "
expected multi disk options on control plane nodes:
    disk type: ${cp_multi_disk_type}
    disk size: $(echo ${cp_multi_disk} | jq -r '.disk_size')
    disk caching type: $(echo ${cp_multi_disk} | jq -r '.caching_type')
    disk lun id: $(echo ${cp_multi_disk} | jq -r '.lun_id')
    disk storage account type: $(echo ${cp_multi_disk} | jq -r '.storage_account_type')
    disk encryption set: $(echo ${cp_multi_disk} | jq -r '.disk_encyption_set')
    disk security encryption type: $(echo ${cp_multi_disk} | jq -r '.security_encryption_type')
    disk security profle des: $(echo ${cp_multi_disk} | jq -r '.security_profile_des')
    disk mount path: $(echo ${cp_multi_disk} | jq -r '.mount_path')
    "

    master_nodes_list=$(oc get machines.machine.openshift.io -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=master -ojson | jq -r '.items[].metadata.name')
    for master_node in ${master_nodes_list}; do 
        node_json=$(mktemp)
        echo "**********Checking data disk properties on node ${master_node}**********"
        echo "disk settings for data disk of node:"
        az vm show -n ${master_node} -g ${RESOURCE_GROUP} --query "storageProfile.dataDisks[?name == '${master_node}_${cp_multi_disk_name_suffix}']" -ojson | tee -a ${node_json}
        multi_disk_check "${cp_multi_disk}" "${node_json}" || check_result=1

        # check mounted path is correct on node
        if oc debug node/${master_node} -n default -- chroot /host lsblk | grep -i "$(echo ${cp_multi_disk} | jq -r '.mount_path')" | grep "$(echo ${cp_multi_disk} | jq -r '.disk_size')G"; then
            echo "INFO: checking disk mounted path for data disk on node passed!"
        else
            echo "ERROR: checking disk mounted path for data disk on node failed!"
            oc debug node/${master_node} -n default -- chroot /host lsblk
            check_result=1
        fi

        if [[ "${cp_multi_disk_type}" == "swap" ]]; then
            swap_result=$(oc debug node/${master_node} -n default -- chroot /host swapon)
            if [[ -n "${swap_result}" ]]; then
                echo "INFO: swapon checking passed on node!"
            else
                echo "ERROR: swapon checking failed on node!"
                check_result=1
            fi
        fi
    done


    echo "**********Checking controlplanemachineset spec**********"
    echo "disk settings in cpms spec:"
    machine_pool_json=$(mktemp)
    oc get controlplanemachinesets.machine.openshift.io cluster -n openshift-machine-api -ojson | jq -r ".spec.template.\"machines_v1beta1_machine_openshift_io\".spec.providerSpec.value.dataDisks[] | select(.nameSuffix==\"${cp_multi_disk_name_suffix}\")" | tee -a ${machine_pool_json}
    machine_pool_check "${cp_multi_disk}" "${machine_pool_json}" || check_result=1
fi

compute_multi_disk_type="$(yq-go r ${INSTALL_CONFIG} 'compute[0].diskSetup[0].type')"
compute_multi_disk="{}"
if [[ -n "${compute_multi_disk_type}" ]]; then
    compute_multi_disk_name_suffix="$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].nameSuffix')"
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"caching_type\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].cachingType')\"}")
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"disk_size\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].diskSizeGB')\"}")
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"lun_id\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].lun')\"}")
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"storage_account_type\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].managedDisk.storageAccountType')\"}")
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"disk_encyption_set\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].managedDisk.diskEncryptionSet.id')\"}")
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"security_encryption_type\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].managedDisk.securityProfile.securityEncryptionType')\"}")
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"security_profile_des\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].managedDisk.securityProfile.diskEncryptionSet.id')\"}")
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"caching_type\":\"$(yq-go r ${INSTALL_CONFIG} 'compute[0].platform.azure.dataDisks[0].cachingType')\"}")
    if [[ "${compute_multi_disk_type}" == "user-defined" ]]; then
        compute_mount_path=$(yq-go r ${INSTALL_CONFIG} 'compute[0].diskSetup[0].userDefined.mountPath')
    elif [[ "${compute_multi_disk_type}" == "swap" ]]; then
        compute_mount_path="swap"
    fi
    compute_multi_disk=$(echo "${compute_multi_disk}" | jq -c -S ". +={\"mount_path\":\"${compute_mount_path}\"}")

    echo -e "\n
expected multi disk options on compute nodes:
    disk type: ${compute_multi_disk_type}
    disk size: $(echo ${compute_multi_disk} | jq -r '.disk_size')
    disk caching type: $(echo ${compute_multi_disk} | jq -r '.caching_type')
    disk lun id: $(echo ${compute_multi_disk} | jq -r '.lun_id')
    disk storage account type: $(echo ${compute_multi_disk} | jq -r '.storage_account_type')
    disk encryption set: $(echo ${compute_multi_disk} | jq -r '.disk_encyption_set')
    disk security encryption type: $(echo ${compute_multi_disk} | jq -r '.security_encryption_type')
    disk security profle des: $(echo ${compute_multi_disk} | jq -r '.security_profile_des')
    disk mount path: $(echo ${compute_multi_disk} | jq -r '.mount_path')
    "

    compute_nodes_list=$(oc get machines.machine.openshift.io -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=worker -ojson | jq -r '.items[].metadata.name')
    for compute_node in ${compute_nodes_list}; do 
        node_json=$(mktemp)
        echo "**********Checking data disk properties on node ${compute_node}**********"
        echo "disk settings for data disk of node:"
        az vm show -n ${compute_node} -g ${RESOURCE_GROUP} --query "storageProfile.dataDisks[?name == '${compute_node}_${compute_multi_disk_name_suffix}']" -ojson | tee -a ${node_json}
        multi_disk_check "${compute_multi_disk}" "${node_json}" || check_result=1

         # check mounted path is correct on node
        if oc debug node/${compute_node} -n default -- chroot /host lsblk | grep -i "$(echo ${compute_multi_disk} | jq -r '.mount_path')" | grep "$(echo ${compute_multi_disk} | jq -r '.disk_size')G"; then
            echo "INFO: checking disk mounted path for data disk on node passed!"
        else
            echo "ERROR: checking disk mounted path for data disk on node failed!"
            oc debug node/${compute_node} -n default -- chroot /host lsblk
            check_result=1
        fi

        if [[ "${compute_multi_disk_type}" == "swap" ]]; then
            swap_result=$(oc debug node/${compute_node} -n default -- chroot /host swapon)
            if [[ -n "${swap_result}" ]]; then
                echo "INFO: swapon checking passed on node!"
            else
                echo "ERROR: swapon checking failed on node!"
                check_result=1
            fi
        fi

    done

    compute_machineset_list=$(oc get machineset.machine.openshift.io -n openshift-machine-api -ojson  | jq -r '.items[].metadata.name')   
    for compute_machineset in ${compute_machineset_list}; do
        machineset_json=$(mktemp)
        echo "**********Checking machineset ${compute_machineset} spec"
        echo "disk settings for data disk in machinset spec"
        oc get machineset.machine.openshift.io "${compute_machineset}" -n openshift-machine-api -ojson | jq -r ".spec.template.spec.providerSpec.value.dataDisks[] | select(.nameSuffix==\"${compute_multi_disk_name_suffix}\")" | tee -a ${machineset_json}
        machine_pool_check "${compute_multi_disk}" "${machineset_json}" || check_result=1
    done
fi

exit $check_result