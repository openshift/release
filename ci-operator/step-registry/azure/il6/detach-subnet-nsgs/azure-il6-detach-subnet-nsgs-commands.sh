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
#
# How the association is cleared matters, and the obvious spelling is wrong.
#
# '--network-security-group ""' does NOT detach. That argument runs through az's name-or-ID
# resolver, which treats anything that is not already a resource ID as a NAME and prepends the
# subscription and group scaffolding. An empty name yields the malformed ID
# '.../providers/Microsoft.Network/networkSecurityGroups/', which Azure rejects with
# InvalidResourceReference -- az is trying to ATTACH that, not to clear the field. The subnet is
# left exactly as it was. 'az network vnet subnet update --help' documents the sentinel as the
# literal 'null' rather than an empty string.
#
# '--remove networkSecurityGroup' is used in preference to that sentinel: it is a generic update
# argument that drops the key from the payload before the PUT, so it never goes near the
# name-or-ID resolver at all. The documented '--nsg null' is kept as a fallback in case --remove
# rejects a payload shape, and the loop below verifies the outcome either way rather than
# trusting an exit status.
echo
echo "--- this run's subnets"
# Read the NSG id alongside the name. --remove errors if the key is absent, so subnets that
# already have no NSG are skipped rather than detached redundantly.
mapfile -t rows < <(az network vnet subnet list \
    -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
    --query "[?starts_with(name, '${RESOURCE_PREFIX}')].[name, networkSecurityGroup.id]" -o tsv)

if [[ "${#rows[@]}" -eq 0 ]]; then
    echo "No subnets matching '${RESOURCE_PREFIX}' found. Nothing to detach."
fi

for row in "${rows[@]}"; do
    [[ -z "${row}" ]] && continue
    IFS=$'\t' read -r subnet nsg_id <<< "${row}"
    [[ -z "${subnet}" ]] && continue
    if [[ -z "${nsg_id}" ]]; then
        echo "Subnet '${subnet}' carries no NSG; nothing to detach."
        continue
    fi
    echo "Detaching '${nsg_id##*/}' from subnet '${subnet}'..."
    az network vnet subnet update \
        -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" -n "${subnet}" \
        --remove networkSecurityGroup -o none \
        || {
            echo "NOTE: --remove networkSecurityGroup failed; retrying with the --nsg null sentinel."
            az network vnet subnet update \
                -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" -n "${subnet}" \
                --network-security-group null -o none \
                || echo "WARNING: failed to detach the NSG from subnet '${subnet}'"
        }
done

# ------------------------------------------------------------- verify
#
# Assert the outcome, not the exit status. The first version of this step logged three warnings,
# left every NSG attached and still exited 0, so the group delete hit
# InUseNetworkSecurityGroupCannotBeDeleted nine minutes later with no hint as to why. If the
# associations are still in place, that delete cannot succeed, so fail here where the cause is
# visible. Later post steps still run -- ci-operator does not short-circuit the post phase.
echo
echo "This run's subnets and their NSG associations (nsg should be empty for all of them):"
az network vnet subnet list -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
    --query "[?starts_with(name, '${RESOURCE_PREFIX}')].{name:name,nsg:networkSecurityGroup.id}" -o table || true

# The query's own exit status is load-bearing. If Azure rejects or times out this request the
# output is empty, and an empty result is exactly what success looks like -- the step would
# report a verified detach having verified nothing. Check the status before reading the value.
# No pipeline here: piping to tr would make $? tr's status, and tr on an empty result emits a
# newline, which reads as "still attached".
if ! still_attached="$(az network vnet subnet list -g "${RG}" --vnet-name "${AZURE_IL6_VNET_NAME}" \
        --query "[?starts_with(name, '${RESOURCE_PREFIX}')] | [?networkSecurityGroup].name" -o tsv)"; then
    echo
    echo "ERROR: could not re-read the subnets to verify the detach."
    echo "An unverified detach is indistinguishable from one that silently did nothing, and"
    echo "azure-deprovision-resourcegroup would then fail with"
    echo "InUseNetworkSecurityGroupCannotBeDeleted. Failing here instead."
    exit 1
fi
still_attached="${still_attached//$'\r'/}"

if [[ -n "${still_attached}" ]]; then
    echo
    echo "ERROR: these subnets still reference an NSG in the per-run group:"
    echo "${still_attached}" | sed 's/^/  /'
    echo "azure-deprovision-resourcegroup will fail with InUseNetworkSecurityGroupCannotBeDeleted"
    echo "and the per-run group will leak. Clear these associations before re-running."
    exit 1
fi

echo
echo "Detach complete. No subnet, NSG, resource group or VNet was deleted by this step."
