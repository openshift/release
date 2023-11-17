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

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
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

#####################################
##########Create Bastion#############
#####################################
echo "azure vhd uri: ${bastion_source_vhd_uri}"

echo "Create a Storage Account for bastion vhd"
# 'account_name' must have length less than 24, so hardcode the basion sa name
sa_name_prefix=$(echo "${NAMESPACE}" | sed "s/ci-op-//" | sed 's/[-_]//g')
sa_name="${sa_name_prefix}${UNIQUE_HASH}basa"
run_command "az storage account create -g ${bastion_rg} --name ${sa_name} --kind Storage --sku Standard_LRS" &&
account_key=$(az storage account keys list -g ${bastion_rg} --account-name ${sa_name} --query "[0].value" -o tsv) || exit 3

echo "Copy bastion vhd from public blob URI to the bastion Storage Account"
storage_contnainer="${bastion_name}vhd"
vhd_name=$(basename "${bastion_source_vhd_uri}")
status="unknown"
run_command "az storage container create --name ${storage_contnainer} --account-name ${sa_name} --account-key ${account_key}" &&
run_command "az storage blob copy start --account-name ${sa_name} --account-key ${account_key} --destination-blob ${vhd_name} --destination-container ${storage_contnainer} --source-uri '${bastion_source_vhd_uri}'" || exit 2
bastion_url_expiry=$(date -u -d "10 hours" '+%Y-%m-%dT%H:%MZ')
bastion_url=$(az storage blob generate-sas -c ${storage_contnainer} -n ${vhd_name} --https-only --full-uri --permissions r --expiry ${bastion_url_expiry} --account-name ${sa_name} --account-key ${account_key} -o tsv)
try=0 retries=30 interval=60
while [ X"${status}" != X"success" ] && [ $try -lt $retries ]; do
    echo "check copy complete, ${try} try..."
    #cmd="az storage blob show --container-name ${storage_contnainer} --name '${vhd_name}' --account-name ${sa_name} --account-key ${account_key} -o tsv --query properties.copy.status"
    cmd="az storage blob show --blob-url '${bastion_url}' -o tsv --query properties.copy.status"
    echo "Command: $cmd"
    status=$(eval "$cmd" || echo "pending")
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
open_port="22 873 3128 3129 5000 6001 6002" bastion_nsg="${bastion_name}-nsg" bastion_subnet="${bastion_name}Subnet"
run_command "az network nsg create -g ${bastion_rg} -n ${bastion_nsg}" &&
run_command "az network nsg rule create -g ${bastion_rg} --nsg-name '${bastion_nsg}' -n '${bastion_name}-allow' --priority 1000 --access Allow --source-port-ranges '*' --destination-port-ranges ${open_port}" &&
#subnet cidr for int service is hard code, it should be a sub rang of the whole VNet cidr, and not conflicts with master subnet and worker subnet
bastion_subnet_cidr="10.0.99.0/24"
if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    # for ash wwt, the parameter name get changed
    vnet_subnet_address_parameter="--address-prefix ${bastion_subnet_cidr}"
else
    vnet_subnet_address_parameter="--address-prefixes ${bastion_subnet_cidr}"
fi
run_command "az network vnet subnet create -g ${bastion_rg} --vnet-name ${bastion_vnet_name} -n ${bastion_subnet} ${vnet_subnet_address_parameter} --network-security-group ${bastion_nsg}" || exit 2

echo "Create bastion vm"
if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    workdir=$(mktemp -d)
    bastion_vm_arm_template="${workdir}/bastion_vm.json"
    cat > "${bastion_vm_arm_template}" << EOF
{
    "\$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vmName" : {
            "type" : "string",
            "minLength" : 1
        },
        "vnetName" : {
            "type" : "string",
            "minLength" : 1
        },
        "subnetName" : {
            "type" : "string",
            "minLength" : 1
        },
        "vmSize" : {
            "type" : "string",
            "minLength" : 1,
            "defaultValue" : "Standard_DS4_v2"
        },
        "vmImageId" : {
            "type" : "string",
            "minLength" : 1
        },
        "ignitionContent" : {
            "type" : "string",
            "minLength" : 1
        }
    },
    "variables": {
        "location" : "[resourceGroup().location]",
        "nicName" : "[concat(parameters('vmName'), 'VMNic')]",
        "virtualNetworkID" : "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]",
        "SubnetRef" : "[concat(variables('virtualNetworkID'), '/subnets/', parameters('subnetName'))]",
        "PublicIpAddressName" : "[concat(parameters('vmName'), 'PublicIP')]"
    },
    "resources": [
        {
            "type": "Microsoft.Network/publicIPAddresses",
            "apiVersion": "2017-10-01",
            "name": "[variables('PublicIpAddressName')]",
            "location": "[variables('location')]",
            "dependsOn": [],
            "tags": {},
            "properties": {
                "publicIPAllocationMethod": null
            }
        },
        {
            "type": "Microsoft.Network/networkInterfaces",
            "apiVersion": "2015-06-15",
            "name": "[variables('nicName')]",
            "location": "[variables('location')]",
            "dependsOn": [
                "[concat('Microsoft.Network/publicIpAddresses/', variables('PublicIpAddressName'))]"
            ],
            "tags": {},
            "properties": {
                "ipConfigurations": [
                    {
                        "name": "vmIpConfig",
                        "properties": {
                            "privateIPAllocationMethod": "Dynamic",
                            "subnet": {
                                "id": "[variables('SubnetRef')]"
                            },
                            "publicIPAddress": {
                                "id": "[resourceId('Microsoft.Network/publicIPAddresses', variables('PublicIpAddressName'))]"
                            }
                        }
                    }
                ]
            }
        },
        {
            "type": "Microsoft.Compute/virtualMachines",
            "apiVersion": "2017-12-01",
            "name": "[parameters('vmName')]",
            "location": "[variables('location')]",
            "dependsOn": [
                "[concat('Microsoft.Network/networkInterfaces/', variables('nicName'))]"
            ],
            "tags": {},
            "properties": {
                "hardwareProfile": {
                    "vmSize": "[parameters('vmSize')]"
                },
                "networkProfile": {
                    "networkInterfaces": [
                        {
                            "id": "[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]"
                        }
                    ]
                },
                "storageProfile": {
                    "osDisk": {
                        "createOption": "fromImage",
                        "name": null,
                        "caching": "ReadWrite",
                        "managedDisk": {
                            "storageAccountType": null
                        },
                        "diskSizeGb": 99
                    },
                    "imageReference": {
                        "id": "[parameters('vmImageId')]"
                    }
                },
                "osProfile": {
                    "computerName": "[parameters('vmName')]",
                    "adminUsername": "core",
                    "adminPassword": "NotActuallyApplied!",
                    "customData" : "[parameters('ignitionContent')]"
                }
            }
        }
    ]
}
EOF
    arm_deployment_name="${bastion_name}-arm"
    ign_b64="$(cat ${bastion_ignition_file} | base64 -w0)"
    run_command "az deployment group create --resource-group ${bastion_rg} --name ${arm_deployment_name} --template-file '${bastion_vm_arm_template}' --parameters ignitionContent='${ign_b64}' --parameters vmName=${bastion_name} --parameters vnetName=${bastion_vnet_name} --parameters subnetName=${bastion_subnet} --parameters vmSize=Standard_DS1_v2 --parameters vmImageId=${bastion_image_id}"
else
    run_command "az vm create --resource-group ${bastion_rg} --name ${bastion_name} --admin-username core --admin-password 'NotActuallyApplied!' --image '${bastion_image_id}' --os-disk-size-gb 199 --subnet ${bastion_subnet} --vnet-name ${bastion_vnet_name} --nsg '' --size 'Standard_DS1_v2' --debug --custom-data '${bastion_ignition_file}' | tee '${SHARED_DIR}/${bastion_name}_output.json'" 
fi

# sleep for a while to wait registry/proxy image get pulled and services boot up after vm is running
sleep 180

if [ -f "${SHARED_DIR}/${bastion_name}_output.json" ]; then
    # directly get public IP from bastion vm creation output
    bastion_private_ip=$(jq -r ".privateIpAddress" "${SHARED_DIR}/${bastion_name}_output.json")
    bastion_public_ip=$(jq -r ".publicIpAddress" "${SHARED_DIR}/${bastion_name}_output.json")
else
    vm_ip_info_file=$(mktemp)
    run_command "az vm list-ip-addresses --name ${bastion_name} --resource-group ${bastion_rg} | tee '${vm_ip_info_file}'" || exit 2
    bastion_private_ip=$(jq -r ".[].virtualMachine.network.privateIpAddresses[]" "${vm_ip_info_file}")
    bastion_public_ip=$(jq -r ".[].virtualMachine.network.publicIpAddresses[].ipAddress" "${vm_ip_info_file}")
fi

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
