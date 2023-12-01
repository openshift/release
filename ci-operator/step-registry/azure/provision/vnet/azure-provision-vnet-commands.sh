#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function vnet_check() {
    local rg="$1" try=0 retries=15 vnet_list_log="$2"
    az network vnet list -g ${rg} >"${vnet_list_log}"
    while [ X"$(cat "${vnet_list_log}" | jq -r ".[].id" | awk -F"/" '{print $NF}')" == X"" ] && [ $try -lt $retries ]; do
        echo "Did not find vnet yet, waiting..."
        sleep 30
        try=$(expr $try + 1)
        az network vnet list -g ${rg} >"${vnet_list_log}"
    done
    if [ X"$try" == X"$retries" ]; then
        echo "!!!!!!!!!!"
        echo "Something wrong"
        run_command "az network vnet list -g ${rg} -o table"
        return 4
    fi
    return 0
}

function create_disconnected_network() {
    local nsg rg="$1" subnet_nsgs="$2"
    for nsg in $subnet_nsgs; do
        run_command "az network nsg rule create -g ${rg} --nsg-name '${nsg}' -n 'DenyInternet' --priority 1010 --access Deny --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'Internet' --destination-port-ranges '*' --direction Outbound"
        if [[ "${CLUSTER_TYPE}" != "azurestack" ]]; then
            run_command "az network nsg rule create -g ${rg} --nsg-name '${nsg}' -n 'AllowAzureCloud' --priority 1009 --access Allow --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'AzureCloud' --destination-port-ranges '*' --direction Outbound"
        fi
    done
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

rg_file="${SHARED_DIR}/resourcegroup"
if [ -f "${rg_file}" ]; then
    RESOURCE_GROUP=$(cat "${rg_file}")
else
    echo "Did not found an provisoned empty resource group"
    exit 1
fi

run_command "az group show --name $RESOURCE_GROUP"; ret=$?
if [ X"$ret" != X"0" ]; then
    echo "The $RESOURCE_GROUP resrouce group does not exit"
    exit 1
fi

VNET_BASE_NAME="${NAMESPACE}-${UNIQUE_HASH}"

# create vnet
if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    arm_template_folder_name="azurestack"
else
    arm_template_folder_name="azure"
fi
vnet_arm_template_file="/var/lib/openshift-install/upi/${arm_template_folder_name}/01_vnet.json"
run_command "az deployment group create --name ${VNET_BASE_NAME} -g ${RESOURCE_GROUP} --template-file '${vnet_arm_template_file}' --parameters baseName='${VNET_BASE_NAME}'"

#Due to sometime frequent vnet list will return empty, so save vnet list output into a local file
vnet_info_file=$(mktemp)
vnet_check "${RESOURCE_GROUP}" "${vnet_info_file}" || exit 3
vnet_name=$(cat "${vnet_info_file}" | jq -r ".[].id" | awk -F"/" '{print $NF}')
vnet_addressPrefixes=$(cat "${vnet_info_file}" | jq -r ".[].addressSpace.addressPrefixes[]")
#Copied subnets values from ARM templates
controlPlaneSubnet=$(cat "${vnet_info_file}" | jq -r ".[].subnets[].name" | grep "master-subnet")
computeSubnet=$(cat "${vnet_info_file}" | jq -r ".[].subnets[].name" | grep "worker-subnet")

#workaround for BZ#1822903
clusterSubnetSNG="${VNET_BASE_NAME}-nsg"
run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'worker-allow' --priority 1000 --access Allow --source-port-ranges '*' --destination-port-ranges 80 443" || exit 3
#Add port 22 to debug easily and to gather bootstrap log
run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'ssh-allow' --priority 1001 --access Allow --source-port-ranges '*' --destination-port-ranges 22" || exit 3

if [[ ! -z "${AZURE_VNET_TAGS}" ]]; then
  echo "Adding custom tags ${AZURE_VNET_TAGS} on vnet ${vnet_name}"
  vnet_id=$(az network vnet list -g ${RESOURCE_GROUP} --query "[].id" -otsv)
  az tag update --resource-id "${vnet_id}" --operation merge --tags ${AZURE_VNET_TAGS}
  echo "az tag list --resource-id ${vnet_id}" > ${SHARED_DIR}/list_azure_existing_vnet_tags.sh
fi

if [ X"${RESTRICTED_NETWORK}" == X"yes" ]; then
    echo "Remove outbound internet access from the Network Security groups used for master and worker subnets"
    create_disconnected_network "${RESOURCE_GROUP}" "${clusterSubnetSNG}"
fi

# save vnet information to ${SHARED_DIR} for later reference
cat > "${SHARED_DIR}/network_machinecidr.yaml" <<EOF
networking:
  machineNetwork:
  - cidr: "${vnet_addressPrefixes}"
EOF

cat > "${SHARED_DIR}/customer_vnet_subnets.yaml" <<EOF
platform:
  azure:
    networkResourceGroupName: ${RESOURCE_GROUP}
    virtualNetwork: ${vnet_name}
    controlPlaneSubnet: ${controlPlaneSubnet}
    computeSubnet: ${computeSubnet}
EOF
