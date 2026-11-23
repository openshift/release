#!/bin/bash

set -o nounset
set -o pipefail
# Deliberately NOT errexit: this runs in post, and a failure to detach one NSG must not abort the
# rest of teardown, and must not mask the failure the job is being torn down for. Every action
# here is idempotent -- detaching an NSG that is already detached is a no-op.

if [[ ! -f "${SHARED_DIR}/azure_il6_subnet_prefix" ]]; then
    echo "No ${SHARED_DIR}/azure_il6_subnet_prefix found; azure-il6-provision-subnets did not run."
    echo "Nothing to detach."
    exit 0
fi

RESOURCE_PREFIX="$(<"${SHARED_DIR}/azure_il6_subnet_prefix")"

# Guard against an empty or absurd prefix turning the loop below into a wildcard sweep that
# strips NSGs off other runs' subnets, or off the emulator's own public-subnet and GatewaySubnet.
if [[ -z "${RESOURCE_PREFIX}" || "${#RESOURCE_PREFIX}" -lt 8 ]]; then
    echo "ERROR: refusing to touch subnets with implausible prefix '${RESOURCE_PREFIX}'."
    exit 1
fi

RG="${AZURE_IL6_RESOURCE_GROUP}"

# The subnets are commercial-plane resources, so this logs in to commercial Azure with the
# azure-qe principal, exactly as azure-il6-provision-subnets did when it created them.
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az cloud set --name AzureCloud
az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_AUTH_LOCATION}")" \
    -p "$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")" \
    --tenant "$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")" --output none
az account set --subscription "$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

echo "Detaching network security groups from subnets with prefix '${RESOURCE_PREFIX}'"
echo "  resource group : ${RG}                   (NOT deleted)"
echo "  vnet           : ${AZURE_IL6_VNET_NAME}  (NOT deleted)"
echo
echo "This breaks a reference cycle that spans two resource groups and would otherwise deadlock"
echo "teardown:"
echo
echo "    bastion NIC  (per-run group) --> subnet (shared VNet)"
echo "    subnet       (shared VNet)   --> NSG    (per-run group)"
echo
echo "'az group delete' on the per-run group cannot remove an NSG that a subnet still references,"
echo "and the subnet cannot be deleted while the bastion NIC is attached to it. Dropping the"
echo "subnet -> NSG edge first leaves an acyclic order: detach here, then"
echo "azure-deprovision-resourcegroup takes the VM, NIC and NSGs, then"
echo "azure-il6-deprovision-resources deletes the now-unreferenced subnets."

# ------------------------------------------------------------- detach
echo
echo "--- this run's subnets"
# Every prefixed subnet, not only the ones that currently show an NSG. Clearing an association
# that is already clear is a no-op, so an unconditional pass is both simpler and safer than
# filtering on networkSecurityGroup in JMESPath, where a bare 'null' parses as a field name
# rather than a literal.
mapfile -t subnets < <(az network vnet subnet list \
    -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
    --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)

if [[ "${#subnets[@]}" -eq 0 ]]; then
    echo "No subnets matching '${RESOURCE_PREFIX}' found. Nothing to detach."
fi

for subnet in "${subnets[@]}"; do
    [[ -z "${subnet}" ]] && continue
    echo "Detaching NSG from subnet '${subnet}'..."
    # An empty --network-security-group is how az clears the association; there is no
    # dedicated 'disassociate' verb.
    az network vnet subnet update \
        -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" -n "${subnet}" \
        --network-security-group "" -o none \
        || echo "WARNING: failed to detach the NSG from subnet '${subnet}'"
done

# ------------------------------------------------------------- report
echo
echo "This run's subnets and their NSG associations (nsg should be empty for all of them):"
az network vnet subnet list -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
    --query "[?starts_with(name, '${RESOURCE_PREFIX}')].{name:name,nsg:networkSecurityGroup.id}" -o table || true

echo
echo "Detach complete. No subnet, NSG, resource group or VNet was deleted by this step."
