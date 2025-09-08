#!/usr/bin/env bash

set -euo pipefail

function check_node_encryption_at_host() {
    local node_name="$1"
    echo "Checking guest cluster node $node_name"

    np_name=$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node "$node_name" -o jsonpath='{.metadata.labels.hypershift\.openshift\.io/nodePool}')
    if [[ -z "$np_name" ]]; then
        echo "Error: got empty NP name for node $node_name" >&2
        return 1
    fi

    np_encryption_at_host="$(oc get np -n clusters "$np_name" -o jsonpath='{.spec.platform.azure.encryptionAtHost}')"
    if [[ $np_encryption_at_host != "Enabled" ]]; then
        echo "Error: NP $np_name has encryptionAtHost disabled" >&2
        return 1
    fi

    vm_encryption_at_host="$(az vm show --name "$node_name" -g "$hc_rg" --query 'securityProfile.encryptionAtHost' -o tsv)"
    if [[ "${vm_encryption_at_host}" != "true" ]]; then
        echo "Error: encryption at host disabled for VM $node_name" >&2
        return 1
    fi
}

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

echo "Getting resource group from HostedCluster"
hc_rg=$(oc get hc -A -o jsonpath='{.items[0].spec.platform.azure.resourceGroup}')
if [[ -z "$hc_rg" ]]; then
    echo "Error: got empty resource group from HostedCluster" >&2
    exit 1
fi

echo "Verifying osDisks on guest cluster nodes are encrypted with the same disk encryption set"
hc_nodes="$(oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers | awk '{print $1}')"
for hc_node in ${hc_nodes}; do
    check_node_encryption_at_host "$hc_node"
done
