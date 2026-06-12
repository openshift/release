#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# --- Azure login (reused from ipi-azure-post pattern) ---
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name"
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
        -n "${cloud_name}" \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name "${cloud_name}"
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"
$WAS_TRACING && set -x

# --- Load cluster metadata ---
METADATA="${SHARED_DIR}/metadata.json"
CLUSTER_NAME=$(jq -r '.clusterName' "${METADATA}")
INFRA_ID=$(jq -r '.infraID' "${METADATA}")
REGION=$(jq -r '.azure.region' "${METADATA}")
RESOURCE_GROUP=$(jq -r '.azure.resourceGroupName' "${METADATA}")
if [[ -z "${RESOURCE_GROUP}" || "${RESOURCE_GROUP}" == "null" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

JSON_FILE="${ARTIFACT_DIR}/azure-cluster-describe.json"
SUMMARY_FILE="${ARTIFACT_DIR}/azure-cluster-describe.log"
echo "Describing all resources in resource group: ${RESOURCE_GROUP}"

# --- Dump raw JSON via Resource Graph ---
az graph query -q "
    Resources
    | where resourceGroup =~ '${RESOURCE_GROUP}'
    | project name, type, location, tags, properties
    | order by type asc, name asc
" --first 1000 -o json 2>/dev/null | jq '
    del(.data[].properties.osProfile.linuxConfiguration.ssh)
    | del(.data[].properties.osProfile.adminPassword)
    | del(.data[].properties.osProfile.secrets)
' > "${JSON_FILE}" || echo "{}" > "${JSON_FILE}"

echo "Raw JSON written to ${JSON_FILE}"

# --- Parse JSON into human-readable summary ---
{
    echo "============================================"
    echo "Azure Cluster Resource Summary"
    echo "Resource Group: ${RESOURCE_GROUP}"
    echo "Cluster Name:   ${CLUSTER_NAME:-unknown}"
    echo "Infra ID:       ${INFRA_ID:-unknown}"
    echo "Region:         ${REGION:-unknown}"
    echo "Timestamp:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "============================================"
    echo ""

    # --- Resource counts by type ---
    echo "--- Resource Inventory ---"
    jq -r '.data | group_by(.type)[] | "  \(.[0].type)  (\(length))"' "${JSON_FILE}" || true
    jq -r '"  Total: \(.count // 0) resources"' "${JSON_FILE}" || true
    echo ""

    # --- Virtual Machines ---
    echo "--- Virtual Machines ---"
    jq -r '.data[] | select(.type == "microsoft.compute/virtualmachines") |
        "  \(.name)\n    size=\(.properties.hardwareProfile.vmSize)  state=\(.properties.provisioningState)  os=\(.properties.storageProfile.osDisk.osType)  zones=\(.properties.zones // ["none"] | join(","))\n    osDisk: \(.properties.storageProfile.osDisk.name)  sizeGb=\(.properties.storageProfile.osDisk.diskSizeGB // "default")  caching=\(.properties.storageProfile.osDisk.caching)  storageType=\(.properties.storageProfile.osDisk.managedDisk.storageAccountType)  deleteOption=\(.properties.storageProfile.osDisk.deleteOption)\n    bootDiagnostics=\(if .properties.diagnosticsProfile.bootDiagnostics.enabled then (if .properties.diagnosticsProfile.bootDiagnostics.storageUri then "storageUri" else "managed" end) else "disabled" end)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Managed Disks ---
    echo "--- Managed Disks ---"
    jq -r '.data[] | select(.type == "microsoft.compute/disks") |
        "  \(.name)  sizeGb=\(.properties.diskSizeGB)  sku=\(.properties.tier)  state=\(.properties.diskState)  os=\(.properties.osType // "data")  encryption=\(.properties.encryption.type)  diskEncryptionSet=\(.properties.encryption.diskEncryptionSetId // "none" | split("/") | last)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Disk Encryption Sets ---
    echo "--- Disk Encryption Sets ---"
    jq -r '.data[] | select(.type == "microsoft.compute/diskencryptionsets") |
        "  \(.name)  state=\(.properties.provisioningState)  encryptionType=\(.properties.encryptionType)\n    keyVaultKey=\(.properties.activeKey.keyUrl // "none")"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Virtual Networks ---
    echo "--- Virtual Networks ---"
    jq -r '.data[] | select(.type == "microsoft.network/virtualnetworks") |
        "  \(.name)  addressSpace=\(.properties.addressSpace.addressPrefixes | join(","))\n    customDNS: \(if .properties.dhcpOptions.dnsServers and (.properties.dhcpOptions.dnsServers | length) > 0 then .properties.dhcpOptions.dnsServers | join(",") else "no (Azure-provided)" end)\n\(.properties.subnets | map("    subnet: \(.name)  cidr=\(.properties.addressPrefixes // [.properties.addressPrefix // "N/A"] | join(","))\n      nsg=\(.properties.networkSecurityGroup.id // "none" | split("/") | last)  routeTable=\(.properties.routeTable.id // "none" | split("/") | last)") | join("\n"))"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Network Security Groups ---
    echo "--- Network Security Groups ---"
    jq -r '.data[] | select(.type == "microsoft.network/networksecuritygroups") |
        "  \(.name)  rules=\(.properties.securityRules | length)\n\(.properties.securityRules | map("    \(.properties.priority) \(.name)  \(.properties.direction) \(.properties.access) \(.properties.protocol) src=\(.properties.sourceAddressPrefix // (.properties.sourceAddressPrefixes | join(","))) dst-port=\(.properties.destinationPortRange // (.properties.destinationPortRanges | join(",")))") | join("\n"))"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Load Balancers ---
    echo "--- Load Balancers ---"
    jq -r '
        # Build a lookup: frontend config name -> "public" or "private"
        [.data[] | select(.type == "microsoft.network/loadbalancers") | .properties.frontendIPConfigurations[]] as $fes
        | ($fes | map({key: (.id | split("/") | last), value: (if .properties.publicIPAddress.id then "public" else "private" end)}) | from_entries) as $fe_type
        | .data[] | select(.type == "microsoft.network/loadbalancers")
        | (.name | test("-internal$")) as $is_internal
        | "  \(.name)  frontends=\(.properties.frontendIPConfigurations | length)  rules=\(.properties.loadBalancingRules | length)\n    Frontends:\n\(.properties.frontendIPConfigurations | map("      \(.name)  privateIP=\(.properties.privateIPAddress // "none")  publicIP=\(.properties.publicIPAddress.id // "none" | split("/") | last)") | join("\n"))\n    Rules:\n\(.properties.loadBalancingRules | map("      \(.name | split("/") | last)  \(.properties.protocol) \(.properties.frontendPort)->\(.properties.backendPort)") | join("\n"))\(if $is_internal | not then "\n    API server (6443): \([.properties.loadBalancingRules[] | select(.properties.backendPort == 6443) | $fe_type[.properties.frontendIPConfiguration.id | split("/") | last]] | unique | join(",") | if . == "" then "none" else . end)\n    Ingress (80/443): \([.properties.loadBalancingRules[] | select(.properties.backendPort == 80 or .properties.backendPort == 443) | $fe_type[.properties.frontendIPConfiguration.id | split("/") | last]] | unique | join(",") | if . == "" then "none" else . end)" else "" end)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Public IPs ---
    echo "--- Public IPs ---"
    jq -r '.data[] | select(.type == "microsoft.network/publicipaddresses") |
        "  \(.name)  address=\(.properties.ipAddress // "unassigned")  allocation=\(.properties.publicIPAllocationMethod)  version=\(.properties.publicIPAddressVersion)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Network Interfaces ---
    echo "--- Network Interfaces ---"
    jq -r '.data[] | select(.type == "microsoft.network/networkinterfaces") |
        "  \(.name)  acceleratedNet=\(.properties.enableAcceleratedNetworking)\n\(.properties.ipConfigurations | map("    ip=\(.properties.privateIPAddress)  subnet=\(.properties.subnet.id | split("/") | last)  primary=\(.properties.primary)") | join("\n"))"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Private DNS Zones ---
    echo "--- Private DNS Zones ---"
    jq -r '.data[] | select(.type == "microsoft.network/privatednszones") |
        "  \(.name)  records=\(.properties.numberOfRecordSets)  vnets=\(.properties.numberOfVirtualNetworkLinks)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Storage Accounts ---
    echo "--- Storage Accounts ---"
    jq -r '.data[] | select(.type == "microsoft.storage/storageaccounts") |
        "  \(.name)  kind=\(.properties.kind // .tags.kind // "unknown")  state=\(.properties.provisioningState)  httpsOnly=\(.properties.supportsHttpsTrafficOnly)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Route Tables ---
    echo "--- Route Tables ---"
    jq -r '.data[] | select(.type == "microsoft.network/routetables") |
        "  \(.name)  routes=\(.properties.routes | length)  disableBgp=\(.properties.disableBgpRoutePropagation)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # --- Managed Identities ---
    echo "--- Managed Identities ---"
    jq -r '.data[] | select(.type == "microsoft.managedidentity/userassignedidentities") |
        "  \(.name)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    echo "============================================"
    echo "Summary complete"
    echo "============================================"

} > "${SUMMARY_FILE}" 2>&1

echo "Summary written to ${SUMMARY_FILE}"
