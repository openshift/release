#!/bin/bash

set -e
set -u
set -o nounset
set -o errexit
set -o pipefail
set -x

#ls -al /secrets
#cp -rv /secrets/* ${SHARED_DIR}

#export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
#export AWS_REGION="us-east-1"
#export AWS_PAGER=""

ls -al ${CLUSTER_PROFILE_DIR}

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
echo "Logging into Azure Cloud"
# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none



az storage blob download --account-name aroclusterinfo --container-name aro-cluster --name console.url --file ${SHARED_DIR}/console.url --auth-mode login
az storage blob download --account-name aroclusterinfo --container-name aro-cluster --name api.url --file ${SHARED_DIR}/api.url --auth-mode login
az storage blob download --account-name aroclusterinfo --container-name aro-cluster --name kubeconfig --file ${SHARED_DIR}/kubeconfig --auth-mode login

## prepare kubeconfig
#aws s3 cp s3://${BUCKET_NAME}/kubeconfig  ${SHARED_DIR}/kubeconfig
cp ${SHARED_DIR}/kubeconfig ${SHARED_DIR}/nested_kubeconfig

## run_time env users
#aws s3 cp s3://${BUCKET_NAME}/runtime_env "${SHARED_DIR}/runtime_env"

#aws s3 cp s3://${BUCKET_NAME}/console.url "${SHARED_DIR}/console.url"
#aws s3 cp s3://${BUCKET_NAME}/api.login "${SHARED_DIR}/api.login"
#aws s3 cp s3://${BUCKET_NAME}/api.url "${SHARED_DIR}/api.url"

#aws s3 cp s3://${BUCKET_NAME}/cluster-name "${SHARED_DIR}/cluster-name"
#aws s3 cp s3://${BUCKET_NAME}/cluster-type "${SHARED_DIR}/cluster-type"