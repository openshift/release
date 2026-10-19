#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deprovision AWS RDS PostgreSQL (and its VPC/SG/subnets) created by
# quay-database-intg-aws-rds. Uses step-specific SHARED_DIR names so this never
# destroys the S3 Terraform state written by quay-deploy-aws-s3.

QUAY_DB_AWS_RDS_TF_ARCHIVE="quay-db-aws-rds-terraform.tgz"
QUAY_DB_AWS_RDS_CONFIG_ARCHIVE="quay-db-aws-rds-config.tgz"
QUAY_DB_AWS_RDS_OUTPUTS_JSON="quay-db-aws-rds-outputs.json"

# Region the database was created in, persisted by the provisioning step.
# Destroy and import must target the same region the resources live in;
# fall back to the same lease env the provisioner resolves from, then the
# legacy default.
QUAY_DB_AWS_REGION=""
if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_REGION" ]]; then
  QUAY_DB_AWS_REGION="$(cat "${SHARED_DIR}/QUAY_DB_AWS_REGION")"
fi
if [[ -z "${QUAY_DB_AWS_REGION}" ]]; then
  QUAY_DB_AWS_REGION="${AWS_REGION_OVERWRITE:-${LEASED_RESOURCE:-us-west-2}}"
fi

echo "Deprovisioning AWS RDS PostgreSQL resources..."

mkdir -p terraform_quay_aws_rds && cd terraform_quay_aws_rds

has_db_identifiers=false
if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_SUBNET_GROUP" || -f "${SHARED_DIR}/QUAY_DB_AWS_SECURITY_GROUP" || -f "${SHARED_DIR}/QUAY_DB_AWS_INSTANCE_ID" || -f "${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS" || -f "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP" || -f "${SHARED_DIR}/${QUAY_DB_AWS_RDS_OUTPUTS_JSON}" ]]; then
  has_db_identifiers=true
fi

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)

export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

# Fallback for a missing or unusable Terraform state archive: rebuild a
# destroyable state from the identifiers the provisioning step persisted.
# The test image has no aws CLI or boto3, so Terraform is the only AWS API
# client available: the config-only archive provides the resource
# definitions, every identifier known is imported (import failures are
# tolerated - the resource may never have been created or may already be
# gone), and terraform destroy runs over whatever imported. The step fails
# only when that destroy fails; resources whose identifiers were never
# persisted are logged for manual cleanup.
cleanup_by_identifiers() {
  local outputs_json="${SHARED_DIR}/${QUAY_DB_AWS_RDS_OUTPUTS_JSON}"
  local instance_id="" sg_id="" vpc_id="" igw_id="" subnet1_id="" subnet2_id=""
  local quay_subnet_group="" quay_security_group="" parameter_group=""

  if [[ -f "${outputs_json}" ]]; then
    instance_id="$(jq -r '.instance_id // empty' "${outputs_json}" 2>/dev/null || true)"
    sg_id="$(jq -r '.sg_id // empty' "${outputs_json}" 2>/dev/null || true)"
    vpc_id="$(jq -r '.vpc_id // empty' "${outputs_json}" 2>/dev/null || true)"
    igw_id="$(jq -r '.igw_id // empty' "${outputs_json}" 2>/dev/null || true)"
    subnet1_id="$(jq -r '.subnet_ids[0] // empty' "${outputs_json}" 2>/dev/null || true)"
    subnet2_id="$(jq -r '.subnet_ids[1] // empty' "${outputs_json}" 2>/dev/null || true)"
  fi
  # The first DNS label of the RDS endpoint is the DB instance identifier.
  if [[ -z "${instance_id}" && -f "${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS" ]]; then
    instance_id="$(cat "${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS")"
    instance_id="${instance_id%%.*}"
  fi
  # Identifier persisted pre-apply by the provisioning step: covers a step
  # killed mid-apply, before outputs/address were written.
  if [[ -z "${instance_id}" && -f "${SHARED_DIR}/QUAY_DB_AWS_INSTANCE_ID" ]]; then
    instance_id="$(cat "${SHARED_DIR}/QUAY_DB_AWS_INSTANCE_ID")"
  fi
  if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_SUBNET_GROUP" ]]; then
    quay_subnet_group="$(cat "${SHARED_DIR}/QUAY_DB_AWS_SUBNET_GROUP")"
  fi
  if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_SECURITY_GROUP" ]]; then
    quay_security_group="$(cat "${SHARED_DIR}/QUAY_DB_AWS_SECURITY_GROUP")"
  fi
  if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP" ]]; then
    parameter_group="$(cat "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP")"
  fi

  if [[ ! -f "${SHARED_DIR}/${QUAY_DB_AWS_RDS_CONFIG_ARCHIVE}" ]]; then
    echo "ERROR: ${QUAY_DB_AWS_RDS_CONFIG_ARCHIVE} missing from SHARED_DIR; cannot rebuild the Terraform config for identifier cleanup. If any resources were created they need manual cleanup (subnet group: ${quay_subnet_group:-unknown}, security group: ${quay_security_group:-unknown}, parameter group: ${parameter_group:-unknown})." >&2
    return 1
  fi

  mkdir -p identifier_fallback && cd identifier_fallback
  cp "${SHARED_DIR}/${QUAY_DB_AWS_RDS_CONFIG_ARCHIVE}" .
  tar -xzf "${QUAY_DB_AWS_RDS_CONFIG_ARCHIVE}"

  # Dummy / persisted values for required variables: after import, resource
  # values come from the state, so only the persisted identifiers matter.
  export TF_VAR_region="${QUAY_DB_AWS_REGION}"
  export TF_VAR_quay_subnet_group="${quay_subnet_group:-quay-subnet-group-dummy}"
  export TF_VAR_quay_security_group="${quay_security_group:-quay-security-group-dummy}"
  export TF_VAR_db_instance_identifier="${instance_id:-quayprowcidb-dummy}"
  export TF_VAR_db_name="${TF_VAR_db_name:-quay}"
  export TF_VAR_db_username="${TF_VAR_db_username:-quayuser}"
  export TF_VAR_db_password="${TF_VAR_db_password:-dummypass}"
  export TF_VAR_engine_version="${TF_VAR_engine_version:-17}"
  export TF_VAR_parameter_group_name="${parameter_group:-quay-scram-pg17-dummy}"
  export TF_VAR_parameter_group_family="${TF_VAR_parameter_group_family:-postgres17}"

  terraform init

  import_resource() {
    local address="$1" id="$2"
    if [[ -z "${id}" ]]; then
      echo "SKIP importing ${address}: identifier unknown; if it was created it needs manual cleanup."
      return 0
    fi
    if terraform import "${address}" "${id}"; then
      echo "Imported ${address} (${id})."
    else
      echo "WARN: could not import ${address} (${id}); it may not exist or may already be deleted." >&2
    fi
  }

  import_resource aws_vpc.quayrds "${vpc_id}"
  import_resource aws_subnet.quayrds1 "${subnet1_id}"
  import_resource aws_subnet.quayrds2 "${subnet2_id}"
  import_resource aws_internet_gateway.quaydbigw "${igw_id}"
  import_resource aws_security_group.quayrds "${sg_id}"
  import_resource aws_db_subnet_group.quayrds "${quay_subnet_group}"
  import_resource aws_db_parameter_group.quay_scram "${parameter_group}"
  import_resource aws_db_instance.quaydb "${instance_id}"

  terraform destroy -auto-approve || return $?
  echo "Identifier-based cleanup completed."
}

archive_usable=true
if [[ -f "${SHARED_DIR}/${QUAY_DB_AWS_RDS_TF_ARCHIVE}" ]]; then
  if ! cp "${SHARED_DIR}/${QUAY_DB_AWS_RDS_TF_ARCHIVE}" . || ! tar -xzvf "${QUAY_DB_AWS_RDS_TF_ARCHIVE}"; then
    archive_usable=false
  fi
else
  archive_usable=false
fi

if [[ "${archive_usable}" == false ]]; then
  if [[ "${has_db_identifiers}" != true ]]; then
    echo "No AWS RDS Terraform archive or identifiers found; nothing to deprovision."
    exit 0
  fi
  echo "AWS RDS Terraform archive missing or unusable; falling back to identifier-based cleanup." >&2
  cleanup_by_identifiers
  exit $?
fi
ls

QUAY_SUBNET_GROUP=$(cat "${SHARED_DIR}/QUAY_DB_AWS_SUBNET_GROUP")
QUAY_SECURITY_GROUP=$(cat "${SHARED_DIR}/QUAY_DB_AWS_SECURITY_GROUP")
QUAY_DB_AWS_PARAMETER_GROUP=""
if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP" ]]; then
  QUAY_DB_AWS_PARAMETER_GROUP=$(cat "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP")
fi

echo "Destroying AWS RDS PostgreSQL resources (including per-job parameter group)..."

DB_INSTANCE_ID_DUMMY="quayprowcidb-dummy"
if [[ -f "${SHARED_DIR}/QUAY_DB_AWS_INSTANCE_ID" ]]; then
  DB_INSTANCE_ID_DUMMY="$(cat "${SHARED_DIR}/QUAY_DB_AWS_INSTANCE_ID")"
fi
export TF_VAR_region="${QUAY_DB_AWS_REGION}"
export TF_VAR_quay_subnet_group="${QUAY_SUBNET_GROUP}"
export TF_VAR_quay_security_group="${QUAY_SECURITY_GROUP}"
export TF_VAR_db_instance_identifier="${DB_INSTANCE_ID_DUMMY}"
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
