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

function vnet_check() {
    local rg="$1" try=0 retries=15 
    while [[ -z "$(az network vnet list -g ${rg} -otsv)" ]] && [ $try -lt $retries ]; do
        echo "Did not find vnet yet, waiting..."
        sleep 30
        try=$(expr $try + 1)
    done
    if [ X"$try" == X"$retries" ]; then
        echo "!!!!!!!!!!"
        echo "Something wrong"
        run_command "az network vnet list -g ${rg} -otsv"
        return 1
    fi
    return 0
}

function create_disconnected_network() {
    local nsg rg="$1" subnet_nsgs="$2"
    for nsg in $subnet_nsgs; do
        run_command "az network nsg rule create -g ${rg} --nsg-name '${nsg}' -n 'DenyInternet' --priority 1010 --access Deny --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'Internet' --destination-port-ranges '*' --direction Outbound"
        if [[ "${CLUSTER_TYPE}" != "azurestack" ]]; then
	    if [[ "${ALLOW_AZURE_CLOUD_ACCESS}" == "no" ]] && (( ocp_minor_version >= 17 && ocp_major_version == 4 )); then
	        run_command "az network nsg rule create -g ${rg} --nsg-name '${nsg}' -n 'DenyAzureCloud' --priority 1009 --access Deny --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'AzureCloud' --destination-port-ranges '*' --direction Outbound"
	    else
                run_command "az network nsg rule create -g ${rg} --nsg-name '${nsg}' -n 'AllowAzureCloud' --priority 1009 --access Allow --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'AzureCloud' --destination-port-ranges '*' --direction Outbound"
           fi
        fi
    done
    return 0
}

# calculate the next consecutive subnet for both IPv4 and IPv6 addresses.
# usage: 
#   get_next_subnet 10.0.0.0/24 5
#   get_next_subnet 2001:db8::/64 3
function get_next_subnet() {
    local CIDR=$1
    local COUNT=${2:-1} # Default to 1 if count is not provided

    if [ -z "$CIDR" ]; then
        echo "Usage: get_next_subnet <ip/prefix> [count]"
        echo "Error: Missing CIDR argument." >&2
        return 1
    fi

    python3 <<-EOF
import ipaddress
import sys

try:
    cidr_str = "${CIDR}"
    count = ${COUNT}

    net = ipaddress.ip_network(cidr_str, strict=False)

    current_net = net
    for _ in range(count):
        next_net_addr = current_net.broadcast_address + 1
        current_net = ipaddress.ip_network(f"{next_net_addr}/{net.prefixlen}", strict=False)

        if current_net.network_address < net.network_address:
            print("Error: Address space overflow.", file=sys.stderr)
            sys.exit(1)

        print(f"{current_net.with_prefixlen}")

except ValueError as e:
    print(f"Error: Invalid input. Details: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"An unexpected error occurred: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

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
vnet_name="${VNET_BASE_NAME}-vnet"
controlPlaneSubnet="${VNET_BASE_NAME}-master-subnet"
computeSubnet_prefix="${VNET_BASE_NAME}-worker-subnet"
clusterSubnetSNG="${VNET_BASE_NAME}-nsg"

# create vnet
# vnet/subnet addressprefix are hardcoded in 01_vnet.json arm template
# Use az CLI instead to create vnet/subnet with specified address prefix
#if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
#    arm_template_folder_name="azurestack"
#else
#    arm_template_folder_name="azure"
#fi

#vnet_arm_template_file="/var/lib/openshift-install/upi/${arm_template_folder_name}/01_vnet.json"
#run_command "az deployment group create --name ${VNET_BASE_NAME} -g ${RESOURCE_GROUP} --template-file '${vnet_arm_template_file}' --parameters baseName='${VNET_BASE_NAME}'"

run_command "az network nsg create --name ${clusterSubnetSNG} -g ${RESOURCE_GROUP}"
run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name ${clusterSubnetSNG} -n 'apiserver_in' --priority 101 --access Allow --source-port-ranges '*' --destination-port-ranges 6443"
if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name ${clusterSubnetSNG} -n 'ign_in' --priority 102 --access Allow --source-port-ranges '*' --destination-port-ranges 22623"
fi

vnet_option=""
if [[ "${AZURE_VNET_ENABLE_ENCRYPTION}" == "true" ]]; then
    vnet_option="--enable-encryption true --encryption-policy ${AZURE_VNET_ENCRYPTION_POLICY}"
fi

vnet_ipv6=""
master_ipv6=""
compute_ipv6_subnets=()
compute_ipv4_subnets=()
if [[ "${IPSTACK}" == "dualstack" ]]; then
    vnet_ipv6="${AZURE_VNET_IPV6_ADDRESS_PREFIXES:-fd00:29cc:9e56::/48}"    
    master_ipv6="${AZURE_CONTROL_PLANE_SUBNET_IPV6_PREFIX:-fd00:29cc:9e56::/64}"
    worker_ipv6="${AZURE_COMPUTE_SUBNET_IPV6_PREFIX:-fd00:29cc:9e56:1::/64}"
    readarray -t compute_ipv6_subnets < <(get_next_subnet ${worker_ipv6} $((AZURE_BYO_COMPUTE_SUBNETS_NUMBER - 1)))
    compute_ipv6_subnets=("${AZURE_COMPUTE_SUBNET_IPV6_PREFIX}" "${compute_ipv6_subnets[@]}")
fi
run_command "az network vnet create --name ${vnet_name} -g ${RESOURCE_GROUP} --address-prefixes ${AZURE_VNET_ADDRESS_PREFIXES} ${vnet_ipv6} ${vnet_option}"
run_command "az network vnet subnet create --name ${controlPlaneSubnet} --vnet-name ${vnet_name} -g ${RESOURCE_GROUP} --address-prefix ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} ${master_ipv6} --network-security-group ${clusterSubnetSNG}"

readarray -t compute_ipv4_subnets < <(get_next_subnet ${AZURE_COMPUTE_SUBNET_PREFIX} $((AZURE_BYO_COMPUTE_SUBNETS_NUMBER - 1)))
compute_ipv4_subnets=("${AZURE_COMPUTE_SUBNET_PREFIX}" "${compute_ipv4_subnets[@]}")
for i in $(seq 0 $((AZURE_BYO_COMPUTE_SUBNETS_NUMBER - 1))); do
    if [[ ${#compute_ipv6_subnets[@]} -eq 0 ]]; then
        run_command "az network vnet subnet create --name ${computeSubnet_prefix}-${i} --vnet-name ${vnet_name} -g ${RESOURCE_GROUP} --address-prefix ${compute_ipv4_subnets[$i]} --network-security-group ${clusterSubnetSNG}"
    else
        run_command "az network vnet subnet create --name ${computeSubnet_prefix}-${i} --vnet-name ${vnet_name} -g ${RESOURCE_GROUP} --address-prefix ${compute_ipv4_subnets[$i]} ${compute_ipv6_subnets[$i]} --network-security-group ${clusterSubnetSNG}"
    fi
done

#Due to sometime frequent vnet list will return empty, so save vnet list output into a local file
vnet_check "${RESOURCE_GROUP}"

#workaround for BZ#1822903
run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'worker-allow' --priority 1000 --access Allow --source-port-ranges '*' --destination-port-ranges 80 443" || exit 3
#Add port 22 to debug easily and to gather bootstrap log
run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'ssh-allow' --priority 1001 --access Allow --source-port-ranges '*' --destination-port-ranges 22" || exit 3

if [[ "${AZURE_CUSTOM_NSG}" == "yes" ]]; then
    echo "Disable default network security rule AllowInBoundVnet from VirtualNetwork to VirtualNetwork"
    run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'DenyVnetInbound' --priority 1100 --access Deny --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'VirtualNetwork' --destination-port-ranges '*' --direction Inbound"

    echo "Create network security rules on specific ports from nodes to nodes"
    for i in $(seq 0 $((AZURE_BYO_COMPUTE_SUBNETS_NUMBER - 1))); do
        run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'AllowVnetInboundTCP' --priority 1010 --access Allow --source-port-ranges '*' --source-address-prefixes ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} ${compute_ipv4_subnets[$i]} --destination-address-prefixes ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} ${compute_ipv4_subnets[$i]} --destination-port-ranges 1936 9000-9999 10250-10259 30000-32767 --direction Inbound --protocol Tcp"
        run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'AllowVnetInboundUDP' --priority 1011 --access Allow --source-port-ranges '*' --source-address-prefixes ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} ${compute_ipv4_subnets[$i]} --destination-address-prefixes ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} ${compute_ipv4_subnets[$i]} --destination-port-ranges 4789 6081 9000-9999 500 4500 30000-32767 --direction Inbound --protocol Udp"
    done
    run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'AllowCidr22623InboundTCP' --priority 1012 --access Allow --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} --destination-port-ranges 22623 --direction Inbound --protocol Tcp"
    run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'AllowetcdInboundTCP' --priority 1013 --access Allow --source-port-ranges '*' --source-address-prefixes ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} --destination-address-prefixes ${AZURE_CONTROL_PLANE_SUBNET_PREFIX} --destination-port-ranges 2379-2380 --direction Inbound --protocol Tcp"
    run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'AllowInboundICMP' --priority 1014 --access Allow --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'VirtualNetwork' --destination-port-ranges '*' --direction Inbound --protocol Icmp"
    run_command "az network nsg rule create -g ${RESOURCE_GROUP} --nsg-name '${clusterSubnetSNG}' -n 'AllowInboundESP' --priority 1015 --access Allow --source-port-ranges '*' --source-address-prefixes 'VirtualNetwork' --destination-address-prefixes 'VirtualNetwork' --destination-port-ranges '*' --direction Inbound --protocol Esp"
fi

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
  - cidr: "${AZURE_VNET_ADDRESS_PREFIXES}"
EOF

if [[ "${AZURE_BYO_SUBNETS_ENABLED}" == "yes" ]]; then
     cat > "${SHARED_DIR}/customer_vnet_subnets.yaml" <<EOF
platform:
  azure:
    networkResourceGroupName: ${RESOURCE_GROUP}
    virtualNetwork: ${vnet_name}
    subnets:
    - name: ${controlPlaneSubnet}
      role: control-plane
EOF
    for i in $(seq 0 $((AZURE_BYO_COMPUTE_SUBNETS_NUMBER - 1))); do
        cat >> "${SHARED_DIR}/customer_vnet_subnets.yaml" <<EOF
    - name: ${computeSubnet_prefix}-${i}
      role: node
EOF
    done
else
    cat > "${SHARED_DIR}/customer_vnet_subnets.yaml" <<EOF
platform:
  azure:
    networkResourceGroupName: ${RESOURCE_GROUP}
    virtualNetwork: ${vnet_name}
    controlPlaneSubnet: ${controlPlaneSubnet}
    computeSubnet: ${computeSubnet_prefix}-0
EOF
fi
