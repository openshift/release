#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deprovision Azure Database for PostgreSQL Flexible Server created by
# quay-database-intg-azure-postgres. Uses step-specific SHARED_DIR names so this
# never destroys blob Terraform state or the OpenShift cluster resource group
# written by quay-deploy-azure-blob.

QUAY_DB_AZURE_TF_ARCHIVE="quay-db-azure-postgres-terraform.tgz"

echo "Deprovisioning Azure Database for PostgreSQL..."

mkdir -p terraform_azure_postgres && cd terraform_azure_postgres

# Get Azure credentials from cluster profile (same as provisioning step)
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ ! -r "${AZURE_AUTH_LOCATION}" ]]; then
  echo "ERROR: ${AZURE_AUTH_LOCATION} not found or unreadable." >&2
  exit 1
fi

# Export ARM_* so the azurerm provider can authenticate for terraform destroy
# (same pattern as quay-deprovision). This script does not enable command tracing.
ARM_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")
ARM_TENANT_ID=$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")
ARM_CLIENT_SECRET=$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")
ARM_CLIENT_ID=$(jq -r .clientId "${AZURE_AUTH_LOCATION}")
export ARM_SUBSCRIPTION_ID ARM_TENANT_ID ARM_CLIENT_SECRET ARM_CLIENT_ID

QUAY_DB_AZURE_RESOURCE_GROUP=""
if [[ -f "${SHARED_DIR}/QUAY_DB_AZURE_RESOURCE_GROUP" ]]; then
  QUAY_DB_AZURE_RESOURCE_GROUP=$(cat "${SHARED_DIR}/QUAY_DB_AZURE_RESOURCE_GROUP")
fi

delete_resource_group() {
  if [[ -z "${QUAY_DB_AZURE_RESOURCE_GROUP}" ]]; then
    echo "ERROR: QUAY_DB_AZURE_RESOURCE_GROUP is empty; cannot fall back to az group delete." >&2
    return 1
  fi
  echo "Falling back to az group delete for DB resource group cleanup..." >&2
  # Disable tracing around secret-bearing login arguments.
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  az login --service-principal \
    --username "${ARM_CLIENT_ID}" \
    --password "${ARM_CLIENT_SECRET}" \
    --tenant "${ARM_TENANT_ID}" \
    --output none
  ${WAS_TRACING} && set -x
  az account set --subscription "${ARM_SUBSCRIPTION_ID}"
  az group delete --name "${QUAY_DB_AZURE_RESOURCE_GROUP}" --yes --no-wait
}

has_db_identifiers=false
if [[ -n "${QUAY_DB_AZURE_RESOURCE_GROUP}" || -f "${SHARED_DIR}/QUAY_DB_AZURE_SERVER" || -f "${SHARED_DIR}/QUAY_AZURE_SERVER_FQDN" ]]; then
  has_db_identifiers=true
fi

if [[ ! -f "${SHARED_DIR}/${QUAY_DB_AZURE_TF_ARCHIVE}" ]]; then
  if [[ "${has_db_identifiers}" == true ]]; then
    echo "WARNING: ${QUAY_DB_AZURE_TF_ARCHIVE} missing from SHARED_DIR but DB identifiers are present; attempting resource-group cleanup." >&2
    if ! delete_resource_group; then
      echo "ERROR: Azure DB Terraform archive missing and az group delete failed; resources may leak." >&2
      exit 1
    fi
    echo "Azure Database for PostgreSQL destroyed successfully via resource-group fallback"
    exit 0
  fi
  echo "No Azure DB Terraform archive or identifiers found; nothing to deprovision."
  exit 0
fi

cp "${SHARED_DIR}/${QUAY_DB_AZURE_TF_ARCHIVE}" .
tar -xzvf "${QUAY_DB_AZURE_TF_ARCHIVE}" && ls

QUAY_DB_AZURE_SERVER=""
if [[ -f "${SHARED_DIR}/QUAY_DB_AZURE_SERVER" ]]; then
  QUAY_DB_AZURE_SERVER=$(cat "${SHARED_DIR}/QUAY_DB_AZURE_SERVER")
fi

echo "Destroying Azure Database for PostgreSQL..."

export TF_VAR_resource_group_name="${QUAY_DB_AZURE_RESOURCE_GROUP}"
export TF_VAR_server_name="${QUAY_DB_AZURE_SERVER:-quaypostgresql}"
export TF_VAR_db_name="quay"
export TF_VAR_db_username="quayuser"
export TF_VAR_db_password="dummypass"

terraform init
tf_destroy_rc=0
terraform destroy -auto-approve || tf_destroy_rc=$?

if [[ "${tf_destroy_rc}" -ne 0 ]]; then
  echo "terraform destroy failed with exit code ${tf_destroy_rc}; attempting az group delete fallback" >&2
  if ! delete_resource_group; then
    echo "ERROR: both terraform destroy and az group delete failed" >&2
    exit 1
  fi
fi

echo "Azure Database for PostgreSQL destroyed successfully"
