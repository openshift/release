#!/usr/bin/env bash

set -euo pipefail

# Load the saved Keycloak prefix
if [ ! -f "${SHARED_DIR}/keycloak-prefix" ]; then
  echo "WARN: No keycloak-prefix file found, skipping DNS cleanup"
  exit 0
fi

KEYCLOAK_PREFIX=$(cat ${SHARED_DIR}/keycloak-prefix)
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]] ; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Cleaning up DNS record for Keycloak server"
# Check if the DNS record exists before attempting deletion
if az network dns record-set a show \
  --resource-group ${DNS_ZONE_RG_NAME} \
  --zone-name ${HYPERSHIFT_BASE_DOMAIN} \
  --name ${KEYCLOAK_PREFIX} &> /dev/null; then

  echo "Deleting DNS A record: ${KEYCLOAK_PREFIX}.${HYPERSHIFT_BASE_DOMAIN}"
  az network dns record-set a delete \
    --resource-group ${DNS_ZONE_RG_NAME} \
    --zone-name ${HYPERSHIFT_BASE_DOMAIN} \
    --name ${KEYCLOAK_PREFIX} \
    --yes || {
      echo "ERROR: Failed to delete DNS record ${KEYCLOAK_PREFIX}"
      exit 1
    }

  echo "Successfully deleted DNS record: ${KEYCLOAK_PREFIX}.${HYPERSHIFT_BASE_DOMAIN}"
else
  echo "DNS record ${KEYCLOAK_PREFIX}.${HYPERSHIFT_BASE_DOMAIN} does not exist, skipping deletion"
fi

echo "DNS cleanup completed"
