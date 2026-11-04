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

# FIRST, before anything is deleted. azure-il6-bastion-setup repointed the VNet's dnsServers at
# this bastion so cluster nodes would inherit its resolver. If the bastion is removed while that
# is still in place, the VNet is left pointing at an address that answers nothing -- and the next
# run's bastion cannot resolve its own boot images, let alone the IL6 plane. The preflight can
# repair that, but it should not have to.
if [[ -f "${SHARED_DIR}/azure_il6_vnet_dns_override" ]]; then
    echo "--- restoring VNet DNS servers to the emulator's (${AZURE_IL6_EMULATOR_DNS})"
    # Retried, because this is the one teardown action whose failure is visible to the NEXT run
    # rather than to this one. A single transient ARM error here would hand the next job a VNet
    # that resolves nothing.
    restored="no"
    for attempt in 1 2 3; do
        if az network vnet update -g "${RG}" -n "${AZURE_IL6_VNET_NAME}" \
            --dns-servers ${AZURE_IL6_EMULATOR_DNS} -o none; then
            restored="yes"
            break
        fi
        echo "    attempt ${attempt} failed; retrying in $((attempt * 10))s"
        sleep $((attempt * 10))
    done

    if [[ "${restored}" == "yes" ]]; then
        echo "OK: dnsServers restored before the bastion is removed."
    else
        echo "WARNING: could not restore dnsServers after 3 attempts. The VNet will point at a"
        echo "         bastion this teardown is about to delete. azure-il6-check-prereqs detects"
        echo "         and repairs that at the start of the next run, and the fixture lease keeps"
        echo "         another run from starting in the meantime -- so this is recoverable, but it"
        echo "         should be investigated if it recurs."
    fi
else
    echo "--- VNet DNS servers were never repointed; nothing to restore."
fi

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

echo "--- images"
mapfile -t images < <(az image list -g "${RG}" --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
for image in "${images[@]}"; do
    [[ -z "${image}" ]] && continue
    echo "Deleting image '${image}'..."
    az image delete -g "${RG}" -n "${image}" -o none || echo "WARNING: failed to delete image '${image}'"
done

# The bastion's storage account is the one resource azure-provision-bastionhost does NOT name with
# the run prefix: 'az storage account create' caps names at 24 characters, so that step strips
# 'ci-op-' and every dash from the namespace instead. Reproduce that name rather than prefix-match
# it, or it leaks into the shared group on every run.
sa_name="$(echo "${NAMESPACE}" | sed 's/ci-op-//' | sed 's/[-_]//g')${UNIQUE_HASH}basa"
echo "--- storage account ${sa_name}"
if az storage account show -g "${RG}" -n "${sa_name}" -o none 2>/dev/null; then
    az storage account delete -g "${RG}" -n "${sa_name}" --yes -o none \
        || echo "WARNING: failed to delete storage account '${sa_name}'"
else
    echo "No storage account '${sa_name}' in ${RG}; nothing to delete."
fi

# ----------------------------------------------------------------- private DNS
# azure-provision-bastionhost creates a private DNS zone for the mirror registry and links it to
# the VNet when REGISTER_MIRROR_REGISTRY_DNS is enabled. The A record and the VNet link both carry
# this run's prefix and are removed here. The ZONE is not prefixed -- it is named after the mirror
# registry FQDN, shared by every run, and deliberately left in place.
#
# An earlier revision deleted any zone left with no VNet links. That broke this step's own stated
# contract (nothing is deleted whose name does not carry this run's prefix) and could delete a
# zone another run had just created but not yet linked. One zone per base domain persists in the
# shared group instead; it costs nothing and 'az network private-dns zone create' is happy to
# find it already there.
echo "--- private DNS zones"
mapfile -t zones < <(az network private-dns zone list -g "${RG}" --query '[].name' -o tsv)
for zone in "${zones[@]}"; do
    [[ -z "${zone}" ]] && continue
    # The A record azure-provision-bastionhost adds is named after the bastion, so it is
    # prefix-matched. It has to go even when the zone itself survives, or every run leaves one
    # behind in a zone that is shared and never deleted.
    mapfile -t records < <(az network private-dns record-set a list -g "${RG}" -z "${zone}" \
        --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
    for record in "${records[@]}"; do
        [[ -z "${record}" ]] && continue
        echo "Deleting A record '${record}' from zone '${zone}'..."
        az network private-dns record-set a delete -g "${RG}" -z "${zone}" -n "${record}" --yes -o none \
            || echo "WARNING: failed to delete A record '${record}'"
    done

    mapfile -t links < <(az network private-dns link vnet list -g "${RG}" -z "${zone}" \
        --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv)
    for link in "${links[@]}"; do
        [[ -z "${link}" ]] && continue
        echo "Deleting VNet link '${link}' from zone '${zone}'..."
        az network private-dns link vnet delete -g "${RG}" -z "${zone}" -n "${link}" --yes -o none \
            || echo "WARNING: failed to delete VNet link '${link}'"
    done

    echo "Zone '${zone}' itself is shared and is left in place."
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
