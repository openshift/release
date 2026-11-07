#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

# Commercial plane only. See azure-il6-check-prereqs for why.
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az cloud set --name AzureCloud
az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_AUTH_LOCATION}")" \
    -p "$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")" \
    --tenant "$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")" --output none
az account set --subscription "$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

# Every resource this step creates is named from the namespace + hash so that concurrent runs can
# never collide inside the shared VNet, and so teardown can match on an unambiguous prefix.
RESOURCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
CONTROL_PLANE_SUBNET="${RESOURCE_PREFIX}-master-subnet"
COMPUTE_SUBNET="${RESOURCE_PREFIX}-worker-subnet"
NSG_NAME="${RESOURCE_PREFIX}-nsg"

echo "${RESOURCE_PREFIX}" > "${SHARED_DIR}/azure_il6_subnet_prefix"

echo "Creating network security group '${NSG_NAME}' in '${AZURE_IL6_RESOURCE_GROUP}'..."
az network nsg create -g "${AZURE_IL6_RESOURCE_GROUP}" -n "${NSG_NAME}" -o none

# The cluster is internal-only: its API is never published to the internet, and the only inbound
# traffic it needs is from inside the VNet (the bastion) and from across the tunnels (the emulated
# IL6 control plane). Azure's default rules already allow intra-VNet traffic, so the NSG stays
# empty of custom allow rules -- we only need it to exist so the subnets are not wide open.
# Subnet CIDRs are allocated at run time, not fixed. Unique subnet NAMES do not prevent ADDRESS
# collisions, and nothing serialises access to this VNet -- the azure-qe boskos lease covers a
# region, not this resource group -- so two concurrent runs with constant CIDRs would collide on
# address space and the second would fail. azure-provision-bastionhost already picks its own
# subnet this way; this matches it.
existing_prefixes="$(az network vnet subnet list \
    -g "${AZURE_IL6_RESOURCE_GROUP}" --vnet-name "${AZURE_IL6_VNET_NAME}" -o json \
    | jq -r '[.[] | (.addressPrefix // empty), (.addressPrefixes[]? // empty)] | join(" ")')"
echo "Existing subnet prefixes: ${existing_prefixes:-<none>}"

allocated="$(python3 - "${AZURE_IL6_VNET_CIDR}" ${existing_prefixes} <<'PY'
import ipaddress
import sys

vnet = ipaddress.ip_network(sys.argv[1])
taken = [ipaddress.ip_network(p) for p in sys.argv[2:]]

free = []
for candidate in vnet.subnets(new_prefix=24):
    if any(candidate.overlaps(t) for t in taken):
        continue
    free.append(str(candidate))
    if len(free) == 2:
        break

if len(free) < 2:
    sys.stderr.write("no two free /24s left in %s\n" % vnet)
    sys.exit(1)

print(" ".join(free))
PY
)"

CONTROL_PLANE_CIDR="$(awk '{print $1}' <<<"${allocated}")"
COMPUTE_CIDR="$(awk '{print $2}' <<<"${allocated}")"
if [[ -z "${CONTROL_PLANE_CIDR}" || -z "${COMPUTE_CIDR}" ]]; then
    echo "ERROR: could not allocate two free /24s inside ${AZURE_IL6_VNET_CIDR}."
    exit 1
fi
echo "Allocated control-plane ${CONTROL_PLANE_CIDR}, compute ${COMPUTE_CIDR}"

echo "Creating control-plane subnet '${CONTROL_PLANE_SUBNET}' (${CONTROL_PLANE_CIDR})..."
az network vnet subnet create \
    -g "${AZURE_IL6_RESOURCE_GROUP}" \
    --vnet-name "${AZURE_IL6_VNET_NAME}" \
    -n "${CONTROL_PLANE_SUBNET}" \
    --address-prefix "${CONTROL_PLANE_CIDR}" \
    --network-security-group "${NSG_NAME}" -o none

echo "Creating compute subnet '${COMPUTE_SUBNET}' (${COMPUTE_CIDR})..."
az network vnet subnet create \
    -g "${AZURE_IL6_RESOURCE_GROUP}" \
    --vnet-name "${AZURE_IL6_VNET_NAME}" \
    -n "${COMPUTE_SUBNET}" \
    --address-prefix "${COMPUTE_CIDR}" \
    --network-security-group "${NSG_NAME}" -o none

# Consumed by ipi-conf-azure-provisionednetwork, which merges both files into install-config.
# networkResourceGroupName is the ONLY place the shared group may appear. It must never become
# platform.azure.resourceGroupName, which 'openshift-install destroy' deletes unconditionally.
cat > "${SHARED_DIR}/customer_vnet_subnets.yaml" <<EOF
platform:
  azure:
    networkResourceGroupName: ${AZURE_IL6_RESOURCE_GROUP}
    virtualNetwork: ${AZURE_IL6_VNET_NAME}
    controlPlaneSubnet: ${CONTROL_PLANE_SUBNET}
    computeSubnet: ${COMPUTE_SUBNET}
EOF

cat > "${SHARED_DIR}/network_machinecidr.yaml" <<EOF
networking:
  machineNetwork:
  - cidr: "${AZURE_IL6_VNET_CIDR}"
EOF

echo "----- customer_vnet_subnets.yaml -----"
cat "${SHARED_DIR}/customer_vnet_subnets.yaml"
echo "----- network_machinecidr.yaml -----"
cat "${SHARED_DIR}/network_machinecidr.yaml"
