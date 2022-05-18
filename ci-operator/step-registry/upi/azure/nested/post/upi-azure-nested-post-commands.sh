#!/bin/bash

set -eo pipefail

INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
export AZURE_AUTH_LOCATION

echo "Logging in with az"
AZURE_AUTH_CLIENT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .clientId)
AZURE_AUTH_CLIENT_SECRET=$(cat $AZURE_AUTH_LOCATION | jq -r .clientSecret)
AZURE_AUTH_TENANT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .tenantId)
AZURE_SUBSCRIPTION_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .subscriptionId)
az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p "$AZURE_AUTH_CLIENT_SECRET" --tenant $AZURE_AUTH_TENANT_ID --output none
az account set --subscription ${AZURE_SUBSCRIPTION_ID}

function teardown() {
  # This is for running the gcloud commands
  mock-nss.sh

  echo "Deprovisioning cluster ..."
  az group delete --resource-group "${INSTANCE_PREFIX}" --output=none --yes
}

trap 'teardown' EXIT
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
