#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

export PS4='[$(date "+%Y-%m-%d %H:%M:%S")] '

CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_HOST="$(KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc get route console -n openshift-console -o=jsonpath='{.spec.host}')"
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
while ! az storage blob lease acquire --container-name "$LOCK_CONTAINER_NAME" --blob-name "$LOCK_BLOB_NAME" --account-name "$LOCK_ACCOUNT_NAME" --lease-duration 15 --auth-mode login; do
    echo "Waiting for lease"
    sleep 60
done

eval "az ad app update --id $CONSOLE_CLIENT_ID --web-redirect-uris $CONSOLE_REDIRECT_URIS_NEW"
az ad app show --id "$CONSOLE_CLIENT_ID" --query 'web.redirectUris' -o tsv
