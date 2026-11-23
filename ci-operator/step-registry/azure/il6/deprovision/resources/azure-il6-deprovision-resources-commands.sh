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

# Guard against an empty or absurd prefix turning the loop below into a wildcard sweep across a
# shared VNet that other runs may be using.
if [[ -z "${RESOURCE_PREFIX}" || "${#RESOURCE_PREFIX}" -lt 8 ]]; then
    echo "ERROR: refusing to clean up with implausible prefix '${RESOURCE_PREFIX}'."
    exit 1
fi

RG="${AZURE_IL6_RESOURCE_GROUP}"

# The subnets are commercial-plane resources, so this logs in to commercial Azure with the
# azure-qe principal. The cluster's own resources live on the emulated IL6 plane and are removed
# by 'openshift-install destroy', which runs on the bastion.
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az cloud set --name AzureCloud
az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_AUTH_LOCATION}")" \
    -p "$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")" \
    --tenant "$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")" --output none
az account set --subscription "$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

echo "Cleaning up Azure IL6 subnets with prefix '${RESOURCE_PREFIX}'"
echo "  resource group : ${RG}                   (NOT deleted)"
echo "  vnet           : ${AZURE_IL6_VNET_NAME}  (NOT deleted)"
echo
echo "Everything else this job created on the commercial plane -- the bastion VM, its NIC, public"
echo "IP, disks, image, NSGs, storage account and private DNS zone -- lives in the per-run group"
echo "that azure-deprovision-resourcegroup removes. Only subnets are left here, because a subnet"
echo "is a child resource of the shared VNet and cannot be created anywhere else."

# ${SHARED_DIR}/remove_resources_by_cli.sh -- which carries the mirror registry's public DNS A
# record, added in BASE_RESOURCE_GROUP (os4-common) and so outliving the per-run group -- is not
# sourced here. azure-deprovision-resourcegroup already runs it, and it runs first.

# ----------------------------------------------------------------- subnets
#
# Ordering: this step runs LAST, after azure-il6-detach-subnet-nsgs and then
# azure-deprovision-resourcegroup. Both predecessors are load-bearing, because the bastion's
# references form a cycle across the two groups:
#
#     bastion NIC (per-run group) --> subnet (shared VNet) --> NSG (per-run group)
#
# azure-deprovision-resourcegroup is what takes the bastion VM and its NIC, and so what releases
# the subnet; while a NIC is attached, the delete below returns InUseSubnetCannotBeDeleted. But
# that group delete cannot itself succeed while a subnet still references an NSG inside the group
# -- Azure returns InUseNetworkSecurityGroupCannotBeDeleted and the step dies under errexit,
# leaking the group. azure-il6-detach-subnet-nsgs drops that edge first so both can complete.
echo
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

# ----------------------------------------------------------------- report
echo
echo "Remaining subnets in ${AZURE_IL6_VNET_NAME}:"
az network vnet subnet list -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
    --query '[].{name:name,prefix:addressPrefix}' -o table || true

echo
echo "Anything still carrying this run's prefix in the shared group (should be empty):"
az resource list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].{name:name,type:type}" -o table || true

echo
echo "Cleanup complete. The resource group, VNet, VPN gateway and both IPsec tunnels are untouched."
