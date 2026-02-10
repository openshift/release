#!/usr/bin/env bash

# Note: Do not set -x for this file. This file can trace sensitive info otherwise
set -euo pipefail

AZURE_AUTH_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/client-id)"
AZURE_AUTH_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-updater-v2/client-secret-value)"
AZURE_AUTH_TENANT_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/tenant-id)"
AZURE_AUTH_SUBSCRIPTION_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/subscription-id)"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

export KUBECONFIG
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

echo "Parsing contexts within the kubeconfig"
ext_oidc_context="$(oc config current-context)"
non_ext_oidc_context="$(oc config view -o json | jq -r '.contexts[] | select(.name!="'"$ext_oidc_context"'").name')"
if [[ -z "$non_ext_oidc_context" ]]; then
    echo "No non-external-oidc context found, exiting"
    exit 1
fi
if (( $(echo "$non_ext_oidc_context" | wc -l) > 1 )); then
    echo "More than one non-external-oidc contexts found: $non_ext_oidc_context, exiting"
    exit 1
fi

echo "Switching to the $non_ext_oidc_context context"
oc config use-context "$non_ext_oidc_context"
echo "The KUBECONFIG is $KUBECONFIG" # This line is intentionally added for possible debugging

CONSOLE_HOST="$(oc --kubeconfig="$KUBECONFIG" get route console -n openshift-console -o=jsonpath='{.spec.host}')"
CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_CALLBACK_URI="https://${CONSOLE_HOST}/auth/callback"
CONSOLE_REDIRECT_URIS="$(az ad app show --id "$CONSOLE_CLIENT_ID" --query 'web.redirectUris' -o tsv)"
if ! grep "$CONSOLE_CALLBACK_URI" <<< "$CONSOLE_REDIRECT_URIS"; then
    echo "The URI to remove $CONSOLE_REDIRECT_URIS is not found within the list of redirect uris $CONSOLE_CALLBACK_URI"
    exit 0
fi
CONSOLE_REDIRECT_URIS_NEW="$(echo "$CONSOLE_REDIRECT_URIS" | grep -v "$CONSOLE_CALLBACK_URI" | paste -s -d ' ' -)"

LOCK_ACCOUNT_NAME="$(</var/run/hypershift-azure-lock-blob/account-name)"
LOCK_BLOB_NAME="$(</var/run/hypershift-azure-lock-blob/blob-name)"
LOCK_CONTAINER_NAME="$(</var/run/hypershift-azure-lock-blob/container-name)"

LOCK_ACCOUNT_KEY="$(az storage account keys list --account-name "$LOCK_ACCOUNT_NAME" --query "[0].value" -o tsv)"

while ! az storage blob lease acquire --container-name "$LOCK_CONTAINER_NAME" --blob-name "$LOCK_BLOB_NAME" --account-name "$LOCK_ACCOUNT_NAME" --account-key "$LOCK_ACCOUNT_KEY" --lease-duration 15; do
    echo "Waiting for lease"
    sleep 60
done

eval "az ad app update --id $CONSOLE_CLIENT_ID --web-redirect-uris $CONSOLE_REDIRECT_URIS_NEW"
sleep 60
if az ad app show --id "$CONSOLE_CLIENT_ID" --query 'web.redirectUris' -o tsv | grep "$CONSOLE_CALLBACK_URI" > /dev/null; then
  echo "Warning: the console callback uri is expected to be removed from but still found in the application's redirect uris. Anyway, continuing and not failing the job"
fi
