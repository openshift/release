#!/bin/bash
# For peer-pods setup we need the upper az credentials to be able to
# perform management tasks over the vnet/subnets that are created
# withing the upper resource group.

if [[ "${ENABLEPEERPODS:-false}" != "true" ]]; then
    echo "skip as ENABLEPEERPODS is not true"
    exit 0
fi

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR:-.}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS:-}" == "true" ]]; then
  AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
AZURE_RESOURCE_GROUP="$(cat "${SHARED_DIR:-.}/resourcegroup")"

cat > "${SHARED_DIR:-.}/peerpods_creds" << EOF
export AZURE_CLIENT_ID="${AZURE_CLIENT_ID}"
export AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET}"
export AZURE_TENANT_ID="${AZURE_TENANT_ID}"
export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
export AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
EOF
