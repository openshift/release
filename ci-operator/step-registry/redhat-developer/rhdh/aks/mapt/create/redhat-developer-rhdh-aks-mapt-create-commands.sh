#!/bin/bash

set -e

AZURE_STORAGE_ACCOUNT=$(cat /tmp/secrets/AZURE_STORAGE_ACCOUNT)
AZURE_STORAGE_BLOB=$(cat /tmp/secrets/AZURE_STORAGE_BLOB)
AZURE_STORAGE_KEY=$(cat /tmp/secrets/AZURE_STORAGE_KEY)
ARM_CLIENT_ID=$(cat /tmp/secrets/ARM_CLIENT_ID)
ARM_CLIENT_SECRET=$(cat /tmp/secrets/ARM_CLIENT_SECRET)
ARM_SUBSCRIPTION_ID=$(cat /tmp/secrets/ARM_SUBSCRIPTION_ID)
ARM_TENANT_ID=$(cat /tmp/secrets/ARM_TENANT_ID)
export AZURE_STORAGE_ACCOUNT AZURE_STORAGE_BLOB AZURE_STORAGE_KEY ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID


echo "$RANDOM$RANDOM" > ${SHARED_DIR}/CORRELATE_MAPT
CORRELATE_MAPT=$(cat ${SHARED_DIR}/CORRELATE_MAPT)

mapt azure aks create \
  --project-name "aks" \
  --backed-url "azblob://${AZURE_STORAGE_BLOB}/aks-${CORRELATE_MAPT}" \
  --conn-details-output "${SHARED_DIR}" \
  --version 1.31 \
  --vmsize "Standard_D4as_v6" \
  --spot \
  --spot-eviction-tolerance "low" \
  --spot-excluded-regions "australiaeast" \
  --enable-app-routing
