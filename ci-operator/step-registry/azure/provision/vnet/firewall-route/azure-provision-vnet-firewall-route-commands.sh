#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
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
    echo "Did not find an provisoned empty resource group"
    exit 1
fi

run_command "az group show --name $RESOURCE_GROUP"; ret=$?
if [ X"$ret" != X"0" ]; then
    echo "The $RESOURCE_GROUP resrouce group does not exit"
    exit 1
fi

vnet_file="${SHARED_DIR}/customer_vnet_subnets.yaml"
if [[ -f "${vnet_file}" ]]; then
    vnet_name=$(yq-go r ${vnet_file} "platform.azure.virtualNetwork")
    master_subnet_name=$(yq-go r ${vnet_file} "platform.azure.controlPlaneSubnet")
    worker_subnet_name=$(yq-go r ${vnet_file} "platform.azure.computeSubnet")
else
    echo "Did not find an provisioned vnet"
    exit 1
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
FW="myFirewall"
# Create vnet for FW
run_command "az network vnet create -g ${RESOURCE_GROUP} -n fw-vnet --address-prefix 10.1.0.0/16 --subnet-name AzureFirewallSubnet --subnet-prefix 10.1.1.0/24"

# Peer vnets
# fw-net -> cluster-net
run_command "az network vnet peering create -g ${RESOURCE_GROUP} -n fw2cluster --vnet-name fw-vnet --remote-vnet ${vnet_name} --allow-vnet-access"
# cluster-net -> fw-net with forwarding
run_command "az network vnet peering create -g ${RESOURCE_GROUP} -n cluster2fw --vnet-name ${vnet_name} --remote-vnet fw-vnet  --allow-forwarded-traffic --allow-vnet-access"

# Create FW
run_command "az config set extension.use_dynamic_install=yes_without_prompt"
run_command "az extension add -n azure-firewall"
run_command "az network firewall create -g ${RESOURCE_GROUP} -n ${FW}"

# create static IP
run_command "az network public-ip create --name fw-pip --resource-group ${RESOURCE_GROUP} --allocation-method static --sku standard"

# Configure FW public ip
run_command "az network firewall ip-config create --firewall-name ${FW} --name FW-config --public-ip-address fw-pip --resource-group ${RESOURCE_GROUP} --vnet-name fw-vnet"

# Update config
run_command "az network firewall update --name ${FW} --resource-group ${RESOURCE_GROUP}"

# Get private ip of FW
fwprivaddr=$(az network firewall ip-config list -g ${RESOURCE_GROUP} -f ${FW} --query "[?name=='FW-config'].privateIpAddress" --output tsv)

# Create new table route
run_command "az network route-table create --name Firewall-rt-table --resource-group ${RESOURCE_GROUP} --disable-bgp-route-propagation true"

# Create default route
run_command "az network route-table route create --resource-group ${RESOURCE_GROUP} --name DG-Route --route-table-name Firewall-rt-table --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $fwprivaddr"

# Associate the route table to the cluster subnets
for subnet in "${master_subnet_name}" "${worker_subnet_name}"; do
  run_command "az network vnet subnet update --resource-group ${RESOURCE_GROUP} --vnet-name ${vnet_name} -n ${subnet} --route-table Firewall-rt-table"
done

# Configure APP rules
# Get subnet prefixes
addressPrefix_output=`az network vnet subnet list --vnet-name ${vnet_name} -g ${RESOURCE_GROUP} -o tsv --query '[].{AddressPrefix:addressPrefix}'`
addressPrefix=$(echo $addressPrefix_output)

# Allowlist in official doc https://docs.openshift.com/container-platform/4.12/installing/install_config/configuring-firewall.html
# Azure API
azure_fqdns_list="management.azure.com *.blob.core.windows.net login.microsoftonline.com"
# For nightly build
redhat_fqdns_list="*.ci.openshift.org"
redhat_fqdns_list="${redhat_fqdns_list} *.cloudfront.net"
# For registries
redhat_fqdns_list="${redhat_fqdns_list} registry.redhat.io access.redhat.com quay.io cdn.quay.io cdn01.quay.io cdn02.quay.io cdn03.quay.io sso.redhat.com"
# For Telemetry
redhat_fqdns_list="${redhat_fqdns_list} cert-api.access.redhat.com api.access.redhat.com infogw.api.openshift.com console.redhat.com" 
# Other allowlist
redhat_fqdns_list="${redhat_fqdns_list} mirror.openshift.com storage.googleapis.com *.apps.${CLUSTER_NAME}.${BASE_DOMAIN} quayio-production-s3.s3.amazonaws.com api.openshift.com rhcos.mirror.openshift.com console.redhat.com sso.redhat.com"
# Other allowlist for optional third-party content
redhat_fqdns_list="${redhat_fqdns_list} registry.connect.redhat.com *.s3.dualstack.us-east-1.amazonaws.com *.s3-us-west-2.amazonaws.com"
if [[ "${ENABLE_FIREWALL_FULLLIST}" == "yes" ]]; then
    # The full list for e2e test
    azure_fqdns_list="*azure.com *microsoft.com *microsoftonline.com *windows.net"
    redhat_fqdns_list="*redhat.com *redhat.io *quay.io *openshift.com storage.googleapis.com *.gserviceaccount.com *.s3.dualstack.us-east-1.amazonaws.com"

    # Example of *.google.com
    run_command "az network firewall application-rule create --collection-name App-Coll01 --firewall-name ${FW} --name Allow-Google --protocols Http=80 Https=443 --resource-group ${RESOURCE_GROUP} --target-fqdns *google.com --source-addresses ${addressPrefix} --priority 200 --action Allow"
    # Allow github
    github_fqdns_list="*github.com *rubygems.org *python.org *pypi.org"
    run_command "az network firewall application-rule create --collection-name github --firewall-name ${FW} --name github --protocols Http=80 Https=443 --resource-group ${RESOURCE_GROUP} --target-fqdns ${github_fqdns_list} --source-addresses ${addressPrefix} --priority 500 --action Allow"
    # Allow docker.io
    docker_fqdns_list="*docker.io *docker.com"
    run_command "az network firewall application-rule create --collection-name docker --firewall-name ${FW} --name docker --protocols Http=80 Https=443 --resource-group ${RESOURCE_GROUP} --target-fqdns ${docker_fqdns_list} --source-addresses ${addressPrefix} --priority 600 --action Allow"
fi

# Allow azure / microsoft / windows stuff
run_command "az network firewall application-rule create --collection-name azure_ms --firewall-name ${FW} --name azure --protocols Http=80 Https=443 --resource-group ${RESOURCE_GROUP} --target-fqdns ${azure_fqdns_list} --source-addresses ${addressPrefix} --priority 300 --action Allow"

# Allow redhat / openshift / quay stuff
# seem like nightly payload image from registry.ci.openshift.org is saved on s3, so we need to add *.s3.dualstack.us-east-1.amazonaws.com to whitelist.
# [root@bootstrap ~]# oc image info registry.ci.openshift.org/ocp/release@sha256:c97466158d19a6e6b5563da4365d42ebe5579421b1163f3a2d6778ceb5388aed
# error: cannot retrieve image configuration for manifest sha256:c97466158d19a6e6b5563da4365d42ebe5579421b1163f3a2d6778ceb5388aed: Get "https://ci-dv2np-image-registry-us-east-1-aunteqmixxpqypvdqwbmjbiloeix.s3.dualstack.us-east-1.amazonaws.com/docker/registry/v2/blobs/sha256/22/226e1b80e3ade322573ef77c6581c7ff0e43d1c6a4aeeefaa0188255d6113e9a/data?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAQ3RURDJKRKD6CS57%2F20210114%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20210114T073418Z&X-Amz-Expires=1200&X-Amz-SignedHeaders=host&X-Amz-Signature=4a24faec6da0f2b6b66b43bf5405cca6f4c8b79e708c394e7727529052fe2ae0": EOF
if [[ X"${RESTRICTED_NETWORK}" != X"yes" ]]; then
    run_command "az network firewall application-rule create --collection-name redhat --firewall-name ${FW} --name redhat --protocols Http=80 Https=443 --resource-group ${RESOURCE_GROUP} --target-fqdns ${redhat_fqdns_list} --source-addresses ${addressPrefix} --priority 400 --action Allow"
fi
