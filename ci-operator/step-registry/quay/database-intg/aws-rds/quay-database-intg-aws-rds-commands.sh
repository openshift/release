#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Provision AWS RDS PostgreSQL database for Quay.
# Outputs database connection details and config fragment to SHARED_DIR.
# Uses step-specific SHARED_DIR names so quay-deploy-aws-s3 cannot overwrite
# the RDS Terraform state (deploy writes SHARED_DIR/terraform.tgz).
#
# Creates a per-job DB parameter group with password_encryption=scram-sha-256
# (no dependency on pre-created scram-passwords-postgresql* groups). Destroyed
# with the rest of the Terraform stack on deprovision.

QUAY_DB_AWS_RDS_TF_ARCHIVE="quay-db-aws-rds-terraform.tgz"
QUAY_SUBNET_GROUP="quayprowcisubnetgroup$RANDOM"
QUAY_SECURITY_GROUP="quayprowcisecuritygroup$RANDOM"

QUAY_AWS_RDS_POSTGRESQL_VERSION="$POSTGRESQL_VERSION"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
QUAY_AWS_RDS_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
QUAY_AWS_RDS_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
QUAY_AWS_RDS_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)

# Prefer env credentials so keys are not written into archived Terraform files.
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

echo "Provisioning AWS RDS PostgreSQL (version ${QUAY_AWS_RDS_POSTGRESQL_VERSION})..."

# Build a unique, RDS-valid parameter group name from the CI job when available.
# AWS rules: 1-255 chars, start with a letter, only [a-z0-9-], no trailing/double hyphens.
rds_parameter_group_name() {
  local version="$1"
  local job_name_part uniqueness sanitized max_job_len
  if [[ -n "${JOB_NAME_SAFE:-}" ]]; then
    job_name_part="${JOB_NAME_SAFE}"
  elif [[ -n "${JOB_NAME:-}" ]]; then
    job_name_part="${JOB_NAME}"
  else
    job_name_part="quayci-${UNIQUE_HASH:-${NAMESPACE:-ns}}-${RANDOM}${RANDOM}"
  fi
  uniqueness="${BUILD_ID:-${UNIQUE_HASH:-$RANDOM}}"
  # Lowercase and replace invalid chars with hyphens.
  sanitized="$(printf '%s' "${job_name_part}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  [[ -n "${sanitized}" ]] || sanitized="quayci${RANDOM}"
  # Ensure it starts with a letter.
  [[ "${sanitized}" =~ ^[a-z] ]] || sanitized="q${sanitized}"
  uniqueness="$(printf '%s' "${uniqueness}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  [[ -n "${uniqueness}" ]] || uniqueness="${RANDOM}"

  # Leave room for "quay-scram-pg<ver>-" prefix + "-" + uniqueness (max 255).
  max_job_len=$((255 - ${#version} - ${#uniqueness} - 16))
  (( max_job_len < 8 )) && max_job_len=8
  sanitized="${sanitized:0:${max_job_len}}"
  sanitized="${sanitized%-}"

  printf 'quay-scram-pg%s-%s-%s\n' "${version}" "${sanitized}" "${uniqueness}"
}

AWS_RDS_PARAMETER_GROUP="$(rds_parameter_group_name "${QUAY_AWS_RDS_POSTGRESQL_VERSION}")"
echo "Creating per-job RDS parameter group: ${AWS_RDS_PARAMETER_GROUP} (family postgres${QUAY_AWS_RDS_POSTGRESQL_VERSION})"

# Create Terraform directory for AWS RDS only (S3 is owned by quay-deploy-aws-s3).
mkdir -p terraform_aws_rds && cd terraform_aws_rds
# Pin the RDS dir by absolute path for the EXIT trap below: this script later
# cds into terraform_install_extension for the pg_trgm step, and a trap that
# archives the CWD overwrote the RDS archive with the extension files, which
# broke deprovision (terraform destroy then prompted for var.quay_db_host).
TF_RDS_DIR="$(pwd)"

archive_terraform_state() {
  # Best-effort: timeout/kill may interrupt mid-apply; still try to leave destroyable state.
  # Always archives the RDS dir (never the CWD). The tarball is built in a
  # temp dir so it never contains itself, and is only copied to SHARED_DIR
  # when the tar succeeds, so a failed re-archive cannot clobber a good one.
  local archive_tmp
  archive_tmp="$(mktemp -d)/${QUAY_DB_AWS_RDS_TF_ARCHIVE}"
  if (cd "${TF_RDS_DIR}" && tar -cvzf "${archive_tmp}" --exclude=".terraform" ./*); then
    cp -f "${archive_tmp}" "${SHARED_DIR}/" || true
  fi
}
trap archive_terraform_state EXIT

cat >>variables.tf <<EOF
variable "region" {
  default = "us-west-2"
}

variable "quay_subnet_group" {
}

variable "quay_security_group" {
}

variable "db_name" {
}

variable "db_username" {
}

variable "db_password" {
  sensitive = true
}

variable "engine_version" {
}

variable "parameter_group_name" {
}

variable "parameter_group_family" {
}
EOF

cat >>create_aws_rds_postgresql.tf <<EOF
provider "aws" {
  region = "us-west-2"
}

resource "aws_db_parameter_group" "quay_scram" {
  name   = var.parameter_group_name
  family = var.parameter_group_family

  parameter {
    name         = "password_encryption"
    value        = "scram-sha-256"
    apply_method = "immediate"
  }

  tags = {
    Name = "Quay CI SCRAM passwords"
  }
}

resource "aws_vpc" "quayrds" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "quaydbigw" {
  vpc_id = aws_vpc.quayrds.id
}

resource "aws_route" "route-public" {
  route_table_id         = aws_vpc.quayrds.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.quaydbigw.id
}

resource "aws_subnet" "quayrds1" {
  vpc_id            = aws_vpc.quayrds.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2b"
}

resource "aws_subnet" "quayrds2" {
  vpc_id            = aws_vpc.quayrds.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-2c"
}

resource "aws_db_subnet_group" "quayrds" {
  name       = var.quay_subnet_group
  subnet_ids = [aws_subnet.quayrds1.id, aws_subnet.quayrds2.id]

  tags = {
    Name = "Quay DB subnet group"
  }
}

resource "aws_security_group" "quayrds" {
  name        = var.quay_security_group
  description = "Allow PostgreSQL inbound traffic"
  vpc_id      = aws_vpc.quayrds.id

  ingress {
    description = "PostgreSQL into Quay RDS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "quaydb" {
  # gp3 storage has a 3000 IOPS baseline vs ~100 IOPS for 30 GiB gp2; with
  # gp2 the full e2e suite timed out (2h16m vs ~26m for the in-cluster DB
  # baseline) on DB-bound pages. db.m5.xlarge (4 vCPU / 16 GiB) adds
  # CPU/memory headroom over db.m5.large for the parallel test load.
  allocated_storage    = 30
  storage_type         = "gp3"
  engine               = "postgres"
  engine_version       = var.engine_version
  instance_class       = "db.m5.xlarge"
  db_name              = var.db_name
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = aws_db_parameter_group.quay_scram.name
  publicly_accessible  = true
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.quayrds.id
  vpc_security_group_ids = [aws_security_group.quayrds.id]

  depends_on = [aws_db_parameter_group.quay_scram]
}

output "quaydb_address" {
  value = aws_db_instance.quaydb.address
}

output "quaydb_endpoint" {
  value = aws_db_instance.quaydb.endpoint
}

output "quaydb_name" {
  value = aws_db_instance.quaydb.db_name
}

output "quaydb_username" {
  value = aws_db_instance.quaydb.username
}

output "quaydb_password" {
  value = aws_db_instance.quaydb.password
  sensitive = true
}

output "parameter_group_name" {
  value = aws_db_parameter_group.quay_scram.name
}
EOF

export TF_VAR_quay_subnet_group="${QUAY_SUBNET_GROUP}"
export TF_VAR_quay_security_group="${QUAY_SECURITY_GROUP}"
export TF_VAR_db_name="${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
export TF_VAR_db_username="${QUAY_AWS_RDS_POSTGRESQL_USERNAME}"
export TF_VAR_db_password="${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}"
export TF_VAR_engine_version="${QUAY_AWS_RDS_POSTGRESQL_VERSION}"
export TF_VAR_parameter_group_name="${AWS_RDS_PARAMETER_GROUP}"
export TF_VAR_parameter_group_family="postgres${QUAY_AWS_RDS_POSTGRESQL_VERSION}"

# Persist DB-only identifiers early so deprovision can still clean up after a failed apply.
# Never write QUAY_AWS_S3_BUCKET here — that key belongs to quay-deploy-aws-s3.
echo "${QUAY_SUBNET_GROUP}" > "${SHARED_DIR}/QUAY_DB_AWS_SUBNET_GROUP"
echo "${QUAY_SECURITY_GROUP}" > "${SHARED_DIR}/QUAY_DB_AWS_SECURITY_GROUP"
echo "${AWS_RDS_PARAMETER_GROUP}" > "${SHARED_DIR}/QUAY_DB_AWS_PARAMETER_GROUP"

echo "Initializing Terraform..."
terraform init
tf_apply_rc=0
terraform apply -auto-approve || tf_apply_rc=$?

# Archive state on success and failure so deprovision can destroy partial applies.
archive_terraform_state

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

QUAY_AWS_RDS_POSTGRESQL_ADDRESS=$(terraform output -raw quaydb_address)
echo "${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}" > "${SHARED_DIR}/QUAY_AWS_RDS_POSTGRESQL_ADDRESS"
echo "AWS RDS PostgreSQL provisioning completed"

# Install PostgreSQL extensions in the database
cd .. && mkdir -p terraform_install_extension && cd terraform_install_extension

cat >>variables.tf <<EOF
variable "quay_db_host" {
}

variable "db_username" {
}

variable "db_password" {
  sensitive = true
}

variable "engine_version" {
}

variable "db_name" {
}
EOF

cat >>install_extension.tf <<EOF
terraform {
  required_providers {
    postgresql = {
      source = "cyrilgdn/postgresql"
      version = "1.22.0"
    }
  }
}

provider "postgresql" {
  host            = var.quay_db_host
  username        = var.db_username
  password        = var.db_password
  expected_version = var.engine_version
  sslmode         = "require"
  connect_timeout = 15
}

resource "postgresql_extension" "pg_trgm" {
  name     = "pg_trgm"
  database = var.db_name
}
EOF

export TF_VAR_quay_db_host="${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}"
export TF_VAR_db_username="${QUAY_AWS_RDS_POSTGRESQL_USERNAME}"
export TF_VAR_db_password="${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}"
export TF_VAR_engine_version="${QUAY_AWS_RDS_POSTGRESQL_VERSION}"
export TF_VAR_db_name="${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
terraform init
terraform apply -auto-approve

echo "PostgreSQL extensions installed successfully"

# URL-encode credentials for DB_URI; leave host/db unencoded.
DB_URI_USER=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${QUAY_AWS_RDS_POSTGRESQL_USERNAME}")
DB_URI_PASS=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}")

# Generate Quay configuration fragment for AWS RDS database
cat > "${SHARED_DIR}/quay-database-aws-rds-config.yaml" <<EOF
DB_CONNECTION_ARGS:
  autorollback: true
  threadlocals: true
DB_URI: postgresql://${DB_URI_USER}:${DB_URI_PASS}@${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}:5432/${QUAY_AWS_RDS_POSTGRESQL_DBNAME}
EOF

echo "AWS RDS PostgreSQL provisioning completed successfully"
echo "Database details and config fragment saved to SHARED_DIR"
