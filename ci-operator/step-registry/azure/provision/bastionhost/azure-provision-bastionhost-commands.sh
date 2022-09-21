#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function wait_public_dns() {
    echo "Wait public DNS - $1 take effect"
    local try=0 retries=10

    while [ X"$(dig +short $1)" == X"" ] && [ $try -lt $retries ]; do
        echo "$1 does not take effect yet on internet, waiting..."
        sleep 60
        try=$(expr $try + 1)
    done
    if [ X"$try" == X"$retries" ]; then
        echo "!!!!!!!!!!"
        echo "Something wrong, pls check your dns provider"
        return 4
    fi
    return 0

}

#####################################
##############Initialize#############
#####################################
# dump out from 'openshift-install coreos print-stream-json' on 4.10.0-rc.1
bastion_source_vhd_uri="${BASTION_VHD_URI}"

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
bastion_name="${CLUSTER_NAME}-bastion"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"

if [[ ! -f "${bastion_ignition_file}" ]]; then
  echo "'${bastion_ignition_file}' not found, abort." && exit 1
fi

if [ -z "${RESOURCE_GROUP}" ]; then
  rg_file="${SHARED_DIR}/resourcegroup"
  if [ -f "${rg_file}" ]; then
    bastion_rg=$(cat "${rg_file}")
  else
    echo "Did not find ${rg_file}!"
    exit 1
  fi
else
  bastion_rg="${RESOURCE_GROUP}"
fi

if [ -z "${VNET_NAME}" ]; then
  vnet_file="${SHARED_DIR}/customer_vnet_subnets.yaml"
  if [ -f "${vnet_file}" ]; then
    bastion_vnet_name=$(yq-go r ${vnet_file} 'platform.azure.virtualNetwork')
  else
    echo "Did not find ${vnet_file}!"
    exit 1
  fi
else
  bastion_vnet_name="${VNET_NAME}"
fi

#####################################
###############Log In################
#####################################
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
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

#####################################
##########Create Bastion#############
#####################################
echo "azure vhd uri: ${bastion_source_vhd_uri}"

echo "Create a Storage Account for bastion vhd"
# 'account_name' must have length less than 24, so hardcode the basion sa name
sa_name_prefix=$(echo "${NAMESPACE}" | sed "s/ci-op-//" | sed 's/[-_]//g')
sa_name="${sa_name_prefix}${JOB_NAME_HASH}basa"
run_command "az storage account create -g ${bastion_rg} --name ${sa_name} --kind Storage --sku Standard_LRS" &&
account_key=$(az storage account keys list -g ${bastion_rg} --account-name ${sa_name} --query "[0].value" -o tsv) || exit 3

echo "Copy bastion vhd from public blob URI to the bastion Storage Account"
storage_contnainer="${bastion_name}vhd"
vhd_name=$(basename "${bastion_source_vhd_uri}")
status="unknown"
run_command "az storage container create --name ${storage_contnainer} --account-name ${sa_name}" &&
run_command "az storage blob copy start --account-name ${sa_name} --account-key ${account_key} --destination-blob ${vhd_name} --destination-container ${storage_contnainer} --source-uri '${bastion_source_vhd_uri}'" || exit 2
try=0 retries=15 interval=60
while [ X"${status}" != X"success" ] && [ $try -lt $retries ]; do
    echo "check copy complete, ${try} try..."
    cmd="az storage blob show --container-name ${storage_contnainer} --name '${vhd_name}' --account-name ${sa_name} --account-key ${account_key} -o tsv --query properties.copy.status"
    echo "Command: $cmd"
    status=$(eval "$cmd")
    echo "Status: $status"
    sleep $interval
    try=$(expr $try + 1)
done
if [ X"$status" != X"success" ]; then
    echo  "Something wrong, copy timeout or failed!"
    exit 2
fi
vhd_blob_url=$(az storage blob url --account-name ${sa_name} --account-key ${account_key} -c ${storage_contnainer} -n ${vhd_name} -o tsv)

echo "Deploy the bastion image from bastion vhd"
run_command "az image create --resource-group ${bastion_rg} --name '${bastion_name}-image' --source ${vhd_blob_url} --os-type Linux --storage-sku Standard_LRS" || exit 2
bastion_image_id=$(az image show --resource-group ${bastion_rg} --name "${bastion_name}-image" | jq -r '.id')

echo "Create bastion subnet"
open_port="22 3128 3129 5000 6001 6002" bastion_nsg="${bastion_name}-nsg" bastion_subnet="${bastion_name}Subnet"
run_command "az network nsg create -g ${bastion_rg} -n ${bastion_nsg}" &&
run_command "az network nsg rule create -g ${bastion_rg} --nsg-name '${bastion_nsg}' -n '${bastion_name}-allow' --priority 1000 --access Allow --source-port-ranges '*' --destination-port-ranges ${open_port}" &&
#subnet cidr for int service is hard code, it should be a sub rang of the whole VNet cidr, and not conflicts with master subnet and worker subnet
bastion_subnet_cidr="10.0.99.0/24"
vnet_subnet_address_parameter="--address-prefixes ${bastion_subnet_cidr}"
run_command "az network vnet subnet create -g ${bastion_rg} --vnet-name ${bastion_vnet_name} -n ${bastion_subnet} ${vnet_subnet_address_parameter} --network-security-group ${bastion_nsg}" || exit 2

echo "Create bastion vm"
run_command "az vm create --resource-group ${bastion_rg} --name ${bastion_name} --admin-username core --admin-password 'NotActuallyApplied!' --image '${bastion_image_id}' --os-disk-size-gb 199 --subnet ${bastion_subnet} --vnet-name ${bastion_vnet_name} --nsg '' --size 'Standard_DS1_v2' --debug --custom-data '${bastion_ignition_file}'" || exit 2

# wait for a while, so that azure api return IP successfully
sleep 60
vm_ip_info_file=$(mktemp)
run_command "az vm list-ip-addresses --name ${bastion_name} --resource-group ${bastion_rg} | tee '${vm_ip_info_file}'" || exit 2
bastion_private_ip=$(jq -r ".[].virtualMachine.network.privateIpAddresses[]" "${vm_ip_info_file}")
bastion_public_ip=$(jq -r ".[].virtualMachine.network.publicIpAddresses[].ipAddress" "${vm_ip_info_file}")
if [ X"${bastion_public_ip}" == X"" ] || [ X"${bastion_private_ip}" == X"" ] ; then
    echo "Did not found public or internal IP!"
    exit 1
fi

#####################################
####Register mirror registry DNS#####
#####################################
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
    mirror_registry_host="${bastion_name}.mirror-registry"
    mirror_registry_dns="${mirror_registry_host}.${BASE_DOMAIN}"

    echo "Adding private DNS record for mirror registry"
    private_zone="mirror-registry.${BASE_DOMAIN}"
    dns_vnet_link_name="${bastion_name}-pvz-vnet-link"
    run_command "az network private-dns zone create -g ${bastion_rg} -n ${private_zone}" &&
    run_command "az network private-dns record-set a add-record -g ${bastion_rg} -z ${private_zone} -n ${bastion_name} -a ${bastion_private_ip}" &&
    run_command "az network private-dns link vnet create --name '${dns_vnet_link_name}' --registration-enabled false --resource-group ${bastion_rg} --virtual-network ${bastion_vnet_name} --zone-name ${private_zone}" || exit 2

    echo "Adding public DNS record for mirror registry"
    cmd="az network dns record-set a add-record -g ${BASE_RESOURCE_GROUP} -z ${BASE_DOMAIN} -n ${mirror_registry_host} -a ${bastion_public_ip}"
    run_command "${cmd}" &&
    echo "az network dns record-set a remove-record -g ${BASE_RESOURCE_GROUP} -z ${BASE_DOMAIN} -n ${mirror_registry_host} -a ${bastion_public_ip} || :" >>"${SHARED_DIR}/remove_resources_by_cli.sh"
    
#    wait_public_dns "${mirror_registry_dns}" || exit 2
    echo "Waiting for ${mirror_registry_dns} to be ready..." && sleep 120s
    # save mirror registry dns info
    echo "${mirror_registry_dns}:5000" > "${SHARED_DIR}/mirror_registry_url"
fi

#####################################
#########Save Bastion Info###########
#####################################
echo ${bastion_public_ip} > "${SHARED_DIR}/bastion_public_address"
echo ${bastion_private_ip} > "${SHARED_DIR}/bastion_private_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

proxy_credential=$(cat /var/run/vault/proxy/proxy_creds)
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" > "${SHARED_DIR}/proxyip"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
