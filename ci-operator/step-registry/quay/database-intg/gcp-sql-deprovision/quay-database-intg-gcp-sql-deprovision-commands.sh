#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deprovision Google Cloud SQL PostgreSQL database
# Cleans up resources created by the provisioning step

echo "Deprovisioning Google Cloud SQL PostgreSQL database..."

mkdir -p terraform_quay_gcp_sql && cd terraform_quay_gcp_sql

has_db_identifiers=false
if [[ -f "${SHARED_DIR}/gsql_db_public_ip" || -s "${SHARED_DIR}/client-cert.pem" ]]; then
  has_db_identifiers=true
fi

# Retrieve Terraform state from SHARED_DIR
if [[ ! -f "${SHARED_DIR}/QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz" ]]; then
  if [[ "${has_db_identifiers}" == true ]]; then
    echo "ERROR: QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz missing from SHARED_DIR but GCP SQL identifiers/certs are present; refusing to exit cleanly (resources may leak)." >&2
    exit 1
  fi
  echo "No GCP SQL Terraform archive or identifiers found; nothing to deprovision."
  exit 0
fi

cp "${SHARED_DIR}/QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz" .
tar -xzvf QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz && ls

# Copy GCP auth.json from mounted secret
cp /var/run/quay-qe-gcp-secret/auth.json .

echo "Destroying Google Cloud SQL database..."

# Dummy value for required sensitive variable when state already has resource values.
export TF_VAR_database_password="${TF_VAR_database_password:-dummypass}"

terraform init
terraform destroy -auto-approve

echo "Google Cloud SQL database destroyed successfully"
