#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
export AZURE_AUTH_LOCATION
INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"
AZURE_REGION=centralus

echo "$(date -u --rfc-3339=seconds) - Configuring VM on Azure..."
mkdir -p "${HOME}"/.ssh
mock-nss.sh

# azure will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "${HOME}/.ssh/id_rsa"
chmod 0600 "${HOME}/.ssh/id_rsa"
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${HOME}/.ssh/id_rsa.pub"
pass=$(openssl rand -base64 10)

echo "Logging in with az"
AZURE_AUTH_CLIENT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .clientId)
AZURE_AUTH_CLIENT_SECRET=$(cat $AZURE_AUTH_LOCATION | jq -r .clientSecret)
AZURE_AUTH_TENANT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .tenantId)
AZURE_SUBSCRIPTION_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .subscriptionId)
az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p "$AZURE_AUTH_CLIENT_SECRET" --tenant $AZURE_AUTH_TENANT_ID --output none
echo "Sleeping for 10 mins for debug"
sleep 600
az account set --subscription $AZURE_SUBSCRIPTION_ID
echo "Able to set the subscriptionId"

az group create --name "${INSTANCE_PREFIX}" --location "${AZURE_REGION}" --output none
az vm create --resource-group "${INSTANCE_PREFIX}" \
  --name "${INSTANCE_PREFIX}" \
  --image "/subscriptions/\"${AZURE_SUBSCRIPTION_ID}\"/resourceGroups/os4-common/providers/Microsoft.Compute/galleries/openshift_qe_image/images/crc"  \
  --specialized \
  --nic-delete-option delete \
  --os-disk-delete-option delete \
  --public-ip-sku Standard \
  --size Standard_D4s_v3 \
  --admin-password "${pass}" \
  --output none

az vm open-port --resource-group "${INSTANCE_PREFIX}" --name "${INSTANCE_PREFIX}" --port 22
# VM_IP=$(az vm show -d -g prkumar-crc-test -n prkumar-crc --query publicIps -o tsv)



