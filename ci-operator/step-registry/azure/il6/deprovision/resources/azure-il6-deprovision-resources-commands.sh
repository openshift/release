#!/bin/bash

set -o nounset
set -o pipefail
# Deliberately NOT errexit: teardown is best-effort. A failure to remove one leftover must not
# abort the rest of the cleanup, and must not mask the failure the job is being torn down for.

if [[ ! -f "${SHARED_DIR}/azure_il6_subnet_prefix" ]]; then
    echo "No ${SHARED_DIR}/azure_il6_subnet_prefix found; azure-il6-provision-subnets did not run."
    echo "Nothing to clean up."
    exit 0
fi

RESOURCE_PREFIX="$(<"${SHARED_DIR}/azure_il6_subnet_prefix")"

# Guard against an empty or absurd prefix turning the loops below into a wildcard sweep across a
# shared VNet that other runs may be using.
if [[ -z "${RESOURCE_PREFIX}" || "${#RESOURCE_PREFIX}" -lt 8 ]]; then
    echo "ERROR: refusing to clean up with implausible prefix '${RESOURCE_PREFIX}'."
    exit 1
fi

RG="${AZURE_IL6_RESOURCE_GROUP}"

# The bastion, its subnet and its NSG are commercial-plane resources, so this logs in to
# commercial Azure with the azure-qe principal. The cluster's own resources live on the emulated
# IL6 plane and are removed by 'openshift-install destroy', which runs on the bastion.
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az cloud set --name AzureCloud
az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_AUTH_LOCATION}")" \
    -p "$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")" \
    --tenant "$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")" --output none
az account set --subscription "$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

echo "Cleaning up Azure IL6 resources with prefix '${RESOURCE_PREFIX}'"
echo "  resource group : ${RG}                   (NOT deleted)"
echo "  vnet           : ${AZURE_IL6_VNET_NAME}  (NOT deleted)"

# Anything a provisioning step registered for removal, e.g. the mirror registry's DNS A record.
if [[ -f "${SHARED_DIR}/remove_resources_by_cli.sh" ]]; then
    echo "--- running ${SHARED_DIR}/remove_resources_by_cli.sh"
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/remove_resources_by_cli.sh" || echo "WARNING: remove_resources_by_cli.sh reported errors"
fi

# ----------------------------------------------------------------- bastion VM
# Must go first: while the VM exists its NIC holds the subnet, and while the NIC exists the
# subnet delete below returns InUseSubnetCannotBeDeleted.
echo "--- virtual machines"
mapfile -t vms < <(az vm list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
for vm in "${vms[@]}"; do
    [[ -z "${vm}" ]] && continue
    echo "Deleting VM '${vm}'..."
    az vm delete -g "${RG}" -n "${vm}" --yes -o none || echo "WARNING: failed to delete VM '${vm}'"
done

echo "--- network interfaces"
mapfile -t nics < <(az network nic list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
for nic in "${nics[@]}"; do
    [[ -z "${nic}" ]] && continue
    echo "Deleting NIC '${nic}'..."
    az network nic delete -g "${RG}" -n "${nic}" -o none || echo "WARNING: failed to delete NIC '${nic}'"
done

echo "--- public IP addresses"
mapfile -t pips < <(az network public-ip list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
for pip in "${pips[@]}"; do
    [[ -z "${pip}" ]] && continue
    echo "Deleting public IP '${pip}'..."
    az network public-ip delete -g "${RG}" -n "${pip}" -o none || echo "WARNING: failed to delete public IP '${pip}'"
done

echo "--- managed disks"
mapfile -t disks < <(az disk list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
for disk in "${disks[@]}"; do
    [[ -z "${disk}" ]] && continue
    echo "Deleting disk '${disk}'..."
    az disk delete -g "${RG}" -n "${disk}" --yes -o none || echo "WARNING: failed to delete disk '${disk}'"
done

# ----------------------------------------------------------------- network
echo "--- subnets"
mapfile -t subnets < <(az network vnet subnet list \
    -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
    --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)

if [[ "${#subnets[@]}" -eq 0 ]]; then
    echo "No subnets matching '${RESOURCE_PREFIX}' found."
fi

for subnet in "${subnets[@]}"; do
    [[ -z "${subnet}" ]] && continue
    echo "Deleting subnet '${subnet}'..."
    az network vnet subnet delete -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" -n "${subnet}" -o none \
        || echo "WARNING: failed to delete subnet '${subnet}'"
done

# NSGs last: a subnet still referencing one blocks its deletion.
echo "--- network security groups"
mapfile -t nsgs < <(az network nsg list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
for nsg in "${nsgs[@]}"; do
    [[ -z "${nsg}" ]] && continue
    echo "Deleting network security group '${nsg}'..."
    az network nsg delete -g "${RG}" -n "${nsg}" -o none || echo "WARNING: failed to delete nsg '${nsg}'"
done

# ----------------------------------------------------------------- report
echo
echo "Remaining subnets in ${AZURE_IL6_VNET_NAME}:"
az network vnet subnet list -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
    --query '[].{name:name,prefix:addressPrefix}' -o table || true

echo
echo "Anything still carrying this run's prefix (should be empty):"
az resource list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].{name:name,type:type}" -o table || true

echo
echo "Cleanup complete. The resource group, VNet, VPN gateway and both IPsec tunnels are untouched."
