#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function check_master_ready() {

    local try=0 max_try=20 total_nodes_count=3
    run_command "oc wait --for condition=Progressing=True controlplanemachineset/cluster -n openshift-machine-api --timeout=600s"
    while (( try < max_try )); do
        node_num=$(oc get machine --selector machine.openshift.io/cluster-api-machine-type=master -n openshift-machine-api -o name | wc -l)
        if (( node_num == total_nodes_count )) && oc wait --for condition=Progressing=false controlplanemachineset/cluster -n openshift-machine-api; then
            echo "$(date -u --rfc-3339=seconds) - all master nodes are recreated, cluster get ready"
            break
        fi
        echo -e "\n$(date -u --rfc-3339=seconds) - wait for master nodes to be recreated"
        run_command "oc get controlplanemachineset/cluster -n openshift-machine-api"
        run_command "oc get machine --selector machine.openshift.io/cluster-api-machine-type=master -n openshift-machine-api"
        sleep 300
        try=$(( try + 1 ))
    done

    if (( try == max_try )); then
        echo "ERROR: master nodes recreation check failed!"
        run_command "oc get controlplanemachineset/cluster -n openshift-machine-api"
        run_command "oc get machine --selector machine.openshift.io/cluster-api-machine-type=master -n openshift-machine-api"
        return 1
    fi

    return 0
}

# az should already be there
command -v az
az --version

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
    # Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
    chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
    source ${SHARED_DIR}/azurestack-login-script.sh
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

identity_name=$(az identity list -g ${RESOURCE_GROUP} --query '[].name' -otsv)
echo "Deleting identity ${identity_name} from cluster resource group ${RESOURCE_GROUP}"
run_command "az identity delete --name \"${identity_name}\" -g ${RESOURCE_GROUP}"
echo "Deleted"

# Post-aciton after deleting managed identity created by installer
# * update cpms to remove field managedIdentity, wait for all master nodes recreated
# * update machineset to remove field managedIdentity
# for cpms
echo "Patching controlplanemachineset "
run_command "oc patch controlplanemachineset/cluster -p '[{\"op\":\"remove\",\"path\":\"/spec/template/machines_v1beta1_machine_openshift_io/spec/providerSpec/value/managedIdentity\"}]' --type=json -n openshift-machine-api"
check_master_ready

#for machineset
machineset_list=$(oc get machinesets -n openshift-machine-api -o name)
echo "Patching each machineset to remove field managedIdentity"
for machineset in $machineset_list; do
    run_command "oc patch ${machineset} -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/providerSpec/value/managedIdentity\"}]' --type=json -n openshift-machine-api"
done
