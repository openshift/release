#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deprovision AWS RDS PostgreSQL (and its VPC/SG/subnets) created by
# quay-database-intg-aws-rds. Uses step-specific SHARED_DIR names so this never
# destroys the S3 Terraform state written by quay-deploy-aws-s3.

QUAY_DB_AWS_RDS_TF_ARCHIVE="quay-db-aws-rds-terraform.tgz"

echo "Deprovisioning AWS RDS PostgreSQL resources..."

mkdir -p terraform_quay_aws_rds && cd terraform_quay_aws_rds

has_db_identifiers=false
if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_SUBNET_GROUP" || -f "${SHARED_DIR}/QUAY_DB_AWS_SECURITY_GROUP" || -f "${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS" ]]; then
  has_db_identifiers=true
fi

if [[ ! -f "${SHARED_DIR}/${QUAY_DB_AWS_RDS_TF_ARCHIVE}" ]]; then
  if [[ "${has_db_identifiers}" == true ]]; then
    echo "ERROR: ${QUAY_DB_AWS_RDS_TF_ARCHIVE} missing from SHARED_DIR but RDS identifiers are present; refusing to exit cleanly (resources may leak)." >&2
    exit 1
  fi
  echo "No AWS RDS Terraform archive or identifiers found; nothing to deprovision."
  exit 0
fi

cp "${SHARED_DIR}/${QUAY_DB_AWS_RDS_TF_ARCHIVE}" .
tar -xzvf "${QUAY_DB_AWS_RDS_TF_ARCHIVE}" && ls

QUAY_SUBNET_GROUP=$(cat "${SHARED_DIR}/QUAY_DB_AWS_SUBNET_GROUP")
QUAY_SECURITY_GROUP=$(cat "${SHARED_DIR}/QUAY_DB_AWS_SECURITY_GROUP")
QUAY_DB_AWS_PARAMETER_GROUP=""
if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP" ]]; then
  QUAY_DB_AWS_PARAMETER_GROUP=$(cat "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP")
fi

echo "Destroying AWS RDS PostgreSQL resources (including per-job parameter group)..."

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)

export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

export TF_VAR_quay_subnet_group="${QUAY_SUBNET_GROUP}"
export TF_VAR_quay_security_group="${QUAY_SECURITY_GROUP}"
# Dummy / persisted values for required variables when state already has resource values.
export TF_VAR_db_name="${TF_VAR_db_name:-quay}"
export TF_VAR_db_username="${TF_VAR_db_username:-quayuser}"
export TF_VAR_db_password="${TF_VAR_db_password:-dummypass}"
export TF_VAR_engine_version="${TF_VAR_engine_version:-17}"
export TF_VAR_parameter_group_name="${QUAY_DB_AWS_PARAMETER_GROUP:-quay-scram-pg17-dummy}"
export TF_VAR_parameter_group_family="${TF_VAR_parameter_group_family:-postgres17}"

terraform --version
terraform init
terraform destroy -auto-approve

echo "AWS RDS PostgreSQL resources destroyed successfully"
