#!/usr/bin/env bash

set -euo pipefail
AZURE_AUTH_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/client-id)"
AZURE_AUTH_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-updater-v2/client-secret-value)"
AZURE_AUTH_TENANT_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/tenant-id)"
AZURE_AUTH_SUBSCRIPTION_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/subscription-id)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

set -x

export PS4='[$(date "+%Y-%m-%d %H:%M:%S")] '

if [[ -f "${SHARED_DIR}/cluster-type" && "$(cat "${SHARED_DIR}/cluster-type")" == "rosa" ]]; then
  KUBECONFIG="${SHARED_DIR}/kubeconfig"
  echo "This is ROSA HCP cluster, getting console URL..."
elif [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
  echo "This is hosted cluster, getting console URL..."
else
  KUBECONFIG="${SHARED_DIR}/kubeconfig"
  echo "This is ocp standalone cluster, getting console URL..."
fi

CONSOLE_HOST="$(oc --kubeconfig="$KUBECONFIG" get route console -n openshift-console -o=jsonpath='{.spec.host}')"
CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_CALLBACK_URI="https://${CONSOLE_HOST}/auth/callback"
CONSOLE_REDIRECT_URIS="$(az ad app show --id "$CONSOLE_CLIENT_ID" --query 'web.redirectUris' -o tsv | paste -s -d ' ' -)"

LOCK_ACCOUNT_NAME="$(</var/run/hypershift-azure-lock-blob/account-name)"
LOCK_BLOB_NAME="$(</var/run/hypershift-azure-lock-blob/blob-name)"
LOCK_CONTAINER_NAME="$(</var/run/hypershift-azure-lock-blob/container-name)"

set +x
LOCK_ACCOUNT_KEY="$(az storage account keys list --account-name "$LOCK_ACCOUNT_NAME" --query "[0].value" -o tsv)"

while ! az storage blob lease acquire --container-name "$LOCK_CONTAINER_NAME" --blob-name "$LOCK_BLOB_NAME" --account-name "$LOCK_ACCOUNT_NAME" --account-key "$LOCK_ACCOUNT_KEY" --lease-duration 15; do
    echo "Waiting for lease"
    sleep 60
done
set -x

eval "az ad app update --id $CONSOLE_CLIENT_ID --web-redirect-uris $CONSOLE_REDIRECT_URIS $CONSOLE_CALLBACK_URI"
az ad app show --id "$CONSOLE_CLIENT_ID" --query 'web.redirectUris' -o tsv
