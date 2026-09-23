#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


#Create Azure Storage Account and Storage Container
QUAY_AZURE_TENANT_ID=$(cat /var/run/quay-qe-azure-secret/tenant_id)
QUAY_AZURE_CLIENT_SECRET=$(cat /var/run/quay-qe-azure-secret/client_secret)
QUAY_AZURE_CLIENT_ID=$(cat /var/run/quay-qe-azure-secret/client_id)

#Retrieve Quay Azure APP ID
QUAY_AZURE_APP_ID=$(cat "$SHARED_DIR"/azure_app_id)

az login --service-principal --username $QUAY_AZURE_CLIENT_ID --password $QUAY_AZURE_CLIENT_SECRET --tenant $QUAY_AZURE_TENANT_ID || true

if [[ -n "$QUAY_AZURE_APP_ID" ]]; then
  echo "QUAY_AZURE_APP_ID is $QUAY_AZURE_APP_ID"
  az ad app delete --id $QUAY_AZURE_APP_ID || true
  echo "Deleted Quay Azure APP Successfully"
else
  echo "QUAY_AZURE_APP_ID is Null"
fi