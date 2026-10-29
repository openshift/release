#!/usr/bin/env bash

# Note: Do not set -x for this file. This file can trace sensitive info otherwise
set -euo pipefail
AZURE_AUTH_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/client-id)"
AZURE_AUTH_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-updater-v2/client-secret-value)"
AZURE_AUTH_TENANT_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/tenant-id)"
AZURE_AUTH_SUBSCRIPTION_ID="$(</var/run/hypershift-ext-oidc-app-updater-v2/subscription-id)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

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
REDIRECT_URI_COUNT=$(echo "$CONSOLE_REDIRECT_URIS" | wc -w)
if [[ $REDIRECT_URI_COUNT -gt 20 ]]; then
  echo "WARNING: Application has $REDIRECT_URI_COUNT redirect URIs. Too many! Please check if corresponding redirect-uri-remove step is run correctly and successfully in jobs that reference this step"
  # The uris are considered sensitive info. Doing some mask: keep first 2 and last 3 domain parts, hide middle with X
  masked_uris=""
  for uri in $CONSOLE_REDIRECT_URIS; do
    if [[ "$uri" =~ ^https://([^/]+)(/.*)$ ]]; then
      IFS='.' read -ra parts <<< "${BASH_REMATCH[1]}"
      n=${#parts[@]}
      if [[ $n -gt 5 ]]; then
        masked="https://${parts[0]}.${parts[1]}."
        for ((i=2; i<n-3; i++)); do masked+="$(echo -n "${parts[$i]}" | tr '[:print:]' 'X')."; done
        masked+="${parts[$n-3]}.${parts[$n-2]}.${parts[$n-1]}${BASH_REMATCH[2]}"
      else
        masked="$uri"
      fi
    else
      masked="$uri"
    fi
    [[ -n "$masked_uris" ]] && masked_uris+=" "
    masked_uris+="$masked"
  done
  echo "Existing redirect URIs ($REDIRECT_URI_COUNT):"
  echo "$masked_uris" | tr ' ' '\n'
fi

LOCK_ACCOUNT_NAME="$(</var/run/hypershift-azure-lock-blob/account-name)"
LOCK_BLOB_NAME="$(</var/run/hypershift-azure-lock-blob/blob-name)"
LOCK_CONTAINER_NAME="$(</var/run/hypershift-azure-lock-blob/container-name)"

LOCK_ACCOUNT_KEY="$(az storage account keys list --account-name "$LOCK_ACCOUNT_NAME" --query "[0].value" -o tsv)"

while ! az storage blob lease acquire --container-name "$LOCK_CONTAINER_NAME" --blob-name "$LOCK_BLOB_NAME" --account-name "$LOCK_ACCOUNT_NAME" --account-key "$LOCK_ACCOUNT_KEY" --lease-duration 15; do
    echo "Waiting for lease"
    sleep 60
done

eval "az ad app update --id $CONSOLE_CLIENT_ID --web-redirect-uris $CONSOLE_REDIRECT_URIS $CONSOLE_CALLBACK_URI"
sleep 60
if ! az ad app show --id "$CONSOLE_CLIENT_ID" --query 'web.redirectUris' -o tsv | grep "$CONSOLE_CALLBACK_URI" > /dev/null; then
  echo "Error: the console callback uri is expected to be added to but not found in the application's redirect uris"
  exit 1
fi
