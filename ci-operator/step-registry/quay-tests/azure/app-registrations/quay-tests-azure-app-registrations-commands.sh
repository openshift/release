#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


#Create Azure Storage Account and Storage Container
QUAY_AZURE_TENANT_ID=$(cat /var/run/quay-qe-azure-secret/tenant_id)
QUAY_AZURE_CLIENT_SECRET=$(cat /var/run/quay-qe-azure-secret/client_secret)
QUAY_AZURE_CLIENT_ID=$(cat /var/run/quay-qe-azure-secret/client_id)
QUAY_AZURE_APP_NAME="quayqe$RANDOM"

#Retrieve the Quay APP Name
QUAY_ROUTE=$(cat "$SHARED_DIR"/quayroute)
QUAY_AZURE_CALLBACK="$QUAY_ROUTE/oauth2/azureid/callback"
QUAY_AZURE_CLI="$QUAY_ROUTE/oauth2/azureid/callback/cli"
QUAY_AZURE_ATTACH="$QUAY_ROUTE/oauth2/azureid/callback/attach"

#Generate New Azure APP for Quay, and update the Web Redirect URLS
az login --service-principal --username $QUAY_AZURE_CLIENT_ID --password $QUAY_AZURE_CLIENT_SECRET --tenant $QUAY_AZURE_TENANT_ID
azure_app_id=$(az ad app create --display-name $QUAY_AZURE_APP_NAME | jq '.id' | tr -d '"' | tr -d '\n')
cat $azure_app_id > "$SHARED_DIR"/azure_app_id || true
az ad app update --id $azure_app_id --web-redirect-uris "$QUAY_AZURE_CALLBACK" "$QUAY_AZURE_CLI" "$QUAY_AZURE_ATTACH" || true
echo "Created Quay Azure APP Successfully"