#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

# This step talks to the COMMERCIAL Azure plane only (management.azure.com), using the azure-qe
# service principal. The emulated IL6 plane is not reachable from a CI pod at all -- see the
# ipi-conf-azureil6 and ipi-install-install-in-bastion steps for that half.
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(jq -r .clientId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_CLIENT_SECRET="$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_TENANT_ID="$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_SUBSCRIPTION_ID="$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

errors=0
fail() { echo "ERROR: $*"; errors=$((errors + 1)); }

echo "=================================================================="
echo " Azure IL6 preflight"
echo "   subscription   : ${AZURE_AUTH_SUBSCRIPTION_ID}"
echo "   resource group : ${AZURE_IL6_RESOURCE_GROUP}"
echo "   vnet           : ${AZURE_IL6_VNET_NAME}"
echo "=================================================================="

# ---------------------------------------------------------------- resource group
if [[ "$(az group exists -n "${AZURE_IL6_RESOURCE_GROUP}")" != "true" ]]; then
    fail "resource group '${AZURE_IL6_RESOURCE_GROUP}' does not exist in subscription ${AZURE_AUTH_SUBSCRIPTION_ID}."
    echo "This group is a shared, pre-provisioned fixture. CI never creates it."
    echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"
    exit 1
fi

rg_region="$(az group show -n "${AZURE_IL6_RESOURCE_GROUP}" --query location -o tsv)"
echo "OK   resource group exists, region '${rg_region}'"
if [[ "${rg_region}" != "${AZURE_IL6_REGION}" ]]; then
    fail "resource group is in '${rg_region}' but AZURE_IL6_REGION is '${AZURE_IL6_REGION}'. The cluster's commercial-plane resources must be co-located with the VNet."
fi

# ---------------------------------------------------------------- vnet
if ! az network vnet show -g "${AZURE_IL6_RESOURCE_GROUP}" -n "${AZURE_IL6_VNET_NAME}" -o none 2>/dev/null; then
    fail "VNet '${AZURE_IL6_VNET_NAME}' not found in '${AZURE_IL6_RESOURCE_GROUP}'."
    echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"
    exit 1
fi

vnet_json="$(az network vnet show -g "${AZURE_IL6_RESOURCE_GROUP}" -n "${AZURE_IL6_VNET_NAME}" -o json)"
vnet_prefix="$(jq -r '.addressSpace.addressPrefixes[0] // empty' <<<"${vnet_json}")"
[[ -n "${vnet_prefix}" ]] || fail "VNet has no address space."
echo "OK   vnet address space: ${vnet_prefix}"

# The VNet's DNS servers are the emulator's resolvers, reached across the tunnels. They are the
# only way *.microsoft.scloud resolves for anything in this VNet, bastion included. If they are
# unset the VNet has fallen back to Azure-provided DNS and the IL6 plane is invisible.
mapfile -t dns_servers < <(jq -r '.dhcpOptions.dnsServers[]? // empty' <<<"${vnet_json}")
if [[ "${#dns_servers[@]}" -eq 0 ]]; then
    fail "VNet has no custom DNS servers configured. The emulated IL6 ARM endpoint will not resolve."
else
    echo "OK   vnet DNS servers: ${dns_servers[*]}"
fi

# ---------------------------------------------------------------- free subnet space
used_prefixes="$(jq -r '[.subnets[].addressPrefix] | join(" ")' <<<"${vnet_json}")"
echo "     existing subnets: ${used_prefixes}"

free_count="$(python3 - "${vnet_prefix}" ${used_prefixes} <<'PY'
import ipaddress, sys
vnet = ipaddress.ip_network(sys.argv[1])
used = [ipaddress.ip_network(p) for p in sys.argv[2:]]
free = sum(1 for c in vnet.subnets(new_prefix=24)
           if not any(c.overlaps(u) for u in used))
print(free)
PY
)"
echo "OK   free /24s available: ${free_count}"
if (( free_count < AZURE_IL6_REQUIRED_FREE_SUBNETS )); then
    fail "need ${AZURE_IL6_REQUIRED_FREE_SUBNETS} free /24s, found ${free_count}. Stale subnets from a previous run may need cleaning up."
fi

# ---------------------------------------------------------------- tunnels
# NB: 'az network vpn-connection list' does NOT populate connectionStatus -- it comes back null for
# every entry. The status is only returned by a per-connection 'show'. Listing and filtering on the
# list output silently passes even when every tunnel is down.
mapfile -t connections < <(az network vpn-connection list -g "${AZURE_IL6_RESOURCE_GROUP}" --query '[].name' -o tsv)
if [[ "${#connections[@]}" -eq 0 ]]; then
    fail "no IPsec connections found in '${AZURE_IL6_RESOURCE_GROUP}'. The emulated IL6 plane is unreachable without them."
fi

for conn in "${connections[@]}"; do
    status="$(az network vpn-connection show -g "${AZURE_IL6_RESOURCE_GROUP}" -n "${conn}" --query connectionStatus -o tsv)"
    if [[ "${status}" == "Connected" ]]; then
        echo "OK   tunnel '${conn}': ${status}"
    else
        fail "tunnel '${conn}' is '${status}', expected 'Connected'."
    fi
done

echo "=================================================================="
if (( errors > 0 )); then
    echo "Preflight FAILED with ${errors} error(s). Not provisioning anything."
    echo
    echo "This job depends on a shared emulator environment that CI does not own."
    echo "If the tunnels are down or the fixture has drifted, contact the SHIFT"
    echo "emulator team rather than re-running the job."
    exit 1
fi
echo "Preflight passed."
