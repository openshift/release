#!/bin/bash
set -euo pipefail

echo "az version:"
az version

if az account show --output none 2>/dev/null; then
  echo "Already logged in to Azure"
else
  echo "Not logged in to Azure; looking for credentials in probable locations"
  CRED_FILE=""
  for candidate in \
    "${AZURE_AUTH_LOCATION:-}" \
    "${CLUSTER_PROFILE_DIR:-}/osServicePrincipal.json" \
    "${SHARED_DIR:-}/azure-sp-contributor.json" \
    "${SHARED_DIR:-}/azure_minimal_permission"; do
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      CRED_FILE="${candidate}"
      echo "Found credentials at ${CRED_FILE}"
      break
    fi
  done

  if [[ -z "${CRED_FILE}" ]]; then
    echo "No Azure credentials found in any probable location" >&2
    exit 1
  fi

  AZURE_AUTH_CLIENT_ID=$(jq -r .clientId "${CRED_FILE}")
  AZURE_AUTH_TENANT_ID=$(jq -r .tenantId "${CRED_FILE}")

  # Disable tracing while the client secret is in scope
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  az login --service-principal \
    -u "${AZURE_AUTH_CLIENT_ID}" \
    -p "$(jq -r .clientSecret "${CRED_FILE}")" \
    --tenant "${AZURE_AUTH_TENANT_ID}" \
    --output none
  ${WAS_TRACING} && set -x

  echo "Logged in with service principal ${AZURE_AUTH_CLIENT_ID}"
fi

AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv)
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
echo "Using subscription ${AZURE_SUBSCRIPTION_ID}"
