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
terraform state list

# Workaround for known terraform-provider-google destroy issues (both hit in
# QE before, see the original quay-tests/resource/deprovisioning/gcp-sql step):
# 1. "failed to delete user ... cannot be dropped because some objects depend
#    on it" - https://github.com/hashicorp/terraform-provider-google/issues/3820
# 2. "failed to delete database ... is being accessed by other users" - the
#    Quay pods are still running when this post step executes and keep open
#    connection pools to the external database.
# Removing the user/database from state lets the instance deletion cascade
# everything: dropping a whole instance ignores active sessions and object
# ownership, unlike individual user/database deletion.
if terraform state list | grep -q "google_sql_user"; then
  terraform state rm google_sql_user.users
fi
if terraform state list | grep -q "google_sql_database"; then
  terraform state rm google_sql_database.database
fi

echo "Start to destroy GCP SQL instance"
if ! terraform destroy -auto-approve; then
  echo "terraform destroy failed; retrying after closing Quay database connections" >&2
  # Remove the Quay registry so the operator tears down the pods still
  # holding connections to the Cloud SQL instance.
  if command -v oc >/dev/null 2>&1 && [[ -n "${KUBECONFIG:-}" ]]; then
    oc delete quayregistry quay -n quay-enterprise --ignore-not-found=true || true
  fi
  # Give the operator time to remove the Quay pods and drop their sessions.
  sleep 3m
  terraform destroy -auto-approve
fi

echo "Google Cloud SQL database destroyed successfully"
