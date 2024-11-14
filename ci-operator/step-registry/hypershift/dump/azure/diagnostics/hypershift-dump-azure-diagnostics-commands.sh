#!/usr/bin/env bash

set -euo pipefail

function dump_node_diagnostics() {
    local node_name="$1"
    local nodepool_name=""
    local diagnostics_storage_account_type=""
    local diagnostics_json="/tmp/diagnostics-${node_name}.json"
    local serial_console_log_uri=""
    local serial_console_log_artifact="${ARTIFACT_DIR}/azure_diagnostics_serial_console_${node_name}.log"
    local console_screenshot_uri=""
    local console_screenshot_artifact="${ARTIFACT_DIR}/azure_diagnostics_console_screenshot_${node_name}.bmp"

    echo "Dumping node $node_name"

    nodepool_name=$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node "$node_name" -o jsonpath='{.metadata.labels.hypershift\.openshift\.io/nodePool}')
    diagnostics_storage_account_type="$(oc get np "$nodepool_name" -n clusters -o jsonpath='{.spec.platform.azure.diagnostics.storageAccountType}')"
    if [[ $diagnostics_storage_account_type != "Managed" && $diagnostics_storage_account_type != "UserManaged" ]]; then
        echo "Diagnostics storage account type = $diagnostics_storage_account_type, no need to dump this node"
        return 0
    fi

    az vm boot-diagnostics get-boot-log-uris --resource-group "$RESOURCE_GROUP" --name "$node_name" -o json > "$diagnostics_json"
    serial_console_log_uri="$(jq -r .serialConsoleLogBlobUri "$diagnostics_json")"
    wget -O "$serial_console_log_artifact" "$serial_console_log_uri"
    console_screenshot_uri="$(jq -r .consoleScreenshotBlobUri "$diagnostics_json")"
    wget -O "$console_screenshot_artifact" "$console_screenshot_uri"
}

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

# Ensure that oc commands run against the management cluster by default
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

CLUSTER_NAME="$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c -20)"
RESOURCE_GROUP=$(oc get hc -n clusters "$CLUSTER_NAME" -o jsonpath='{.spec.platform.azure.resourceGroup}')
NODES=$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node -o jsonpath='{.items[*].metadata.name}')
for NODE in $NODES; do
    dump_node_diagnostics "$NODE"
done
