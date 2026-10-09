#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Provision Google Cloud SQL PostgreSQL database for Quay
# Outputs database connection details, SSL certificates, and config fragment to SHARED_DIR

GCP_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
GCP_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
GCP_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)

# Derive provider expected_version (e.g. POSTGRES_17 -> 17) from DB_VERSION.
EXPECTED_VERSION="${DB_VERSION#POSTGRES_}"
QUAY_GCP_SQL_INSTANCE_NAME="quay-postgres-prow${RANDOM}"

QUAY_GCP_SQL_TERRAFORM_PACKAGE="QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz"
mkdir -p QUAY_GCPSQL && cd QUAY_GCPSQL
# Pin the Cloud SQL dir by absolute path for the EXIT trap below: this script
# later cds into the extension directory, and a trap that archives the CWD
# overwrote the DB state archive with the extension files, breaking deprovision.
TF_GCP_SQL_DIR="$(pwd)"

# Copy GCP auth.json from mounted secret to current directory
cp /var/run/quay-qe-gcp-secret/auth.json .

echo "Provisioning Google Cloud SQL PostgreSQL (${DB_VERSION})..."

archive_terraform_state() {
  # Best-effort: timeout/kill may interrupt mid-apply; still try to leave destroyable state.
  # Always archives the Cloud SQL dir (never the CWD). The tarball is built in
  # a temp dir so it never contains itself, and is only copied to SHARED_DIR
  # when the tar succeeds, so a failed re-archive cannot clobber a good one.
  # auth.json stays excluded so GCP credentials never enter the archive.
  local archive_tmp
  archive_tmp="$(mktemp -d)/${QUAY_GCP_SQL_TERRAFORM_PACKAGE}"
  if (cd "${TF_GCP_SQL_DIR}" && tar -cvzf "${archive_tmp}" --exclude=".terraform" --exclude="auth.json" ./*); then
    cp -f "${archive_tmp}" "${SHARED_DIR}/" || true
  fi
}
trap archive_terraform_state EXIT

cat >>variables.tf <<EOF
variable "region" {
  default  = "us-central1"
}

variable "tier" {
  default = "db-custom-2-7680"  # 2 vCPUs, 7.5GB RAM
}

variable "database_version" {
  default = "${DB_VERSION}"
}

variable "database_name" {
  default = "${GCP_POSTGRESQL_DBNAME}"
}

variable "database_username" {
  default = "${GCP_POSTGRESQL_USERNAME}"
}

variable "database_password" {
  sensitive = true
}

EOF

cat >>create_gcp_sql.tf <<EOF
provider "google" {
  credentials = file("auth.json")
  project = "openshift-qe"
  region  = var.region
}

resource "google_sql_database_instance" "instance" {
  name             = "${QUAY_GCP_SQL_INSTANCE_NAME}"
  database_version = var.database_version
  region           = var.region
  deletion_protection = false

  settings {
    tier = var.tier
    edition = "ENTERPRISE"
    availability_type = "ZONAL"

    disk_size         = 10
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled    = true
      ssl_mode = "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
      authorized_networks {
        name  = "allow-all"
        value = "0.0.0.0/0"
      }
    }
  }
}

resource "google_sql_database" "database" {
  name     = var.database_name
  instance = google_sql_database_instance.instance.name
  depends_on = [google_sql_user.users]
}

resource "google_sql_user" "users" {
  name     = var.database_username
  instance = google_sql_database_instance.instance.name
  password = var.database_password
}

resource "google_sql_ssl_cert" "postgres_client_cert" {
  common_name = "quay-certclient"
  instance    = google_sql_database_instance.instance.name
}

output "quay_db_public_ip" {
  value = google_sql_database_instance.instance.public_ip_address
}

output "client_cert" {
  value = google_sql_ssl_cert.postgres_client_cert.cert
  sensitive = true
}

output "client_key" {
  sensitive = true
  value = google_sql_ssl_cert.postgres_client_cert.private_key
}

data "google_sql_ca_certs" "ca_certs" {
  instance = google_sql_database_instance.instance.name
}

locals {
  furthest_expiration_time = reverse(sort([for k, v in data.google_sql_ca_certs.ca_certs.certs : v.expiration_time]))[0]
  latest_ca_cert           = [for v in data.google_sql_ca_certs.ca_certs.certs : v.cert if v.expiration_time == local.furthest_expiration_time]
}

output "db_latest_ca_cert" {
  description = "Latest CA certificate used by the primary database server"
  value       = local.latest_ca_cert[0]
  sensitive   = true
}
EOF

export TF_VAR_database_password="${GCP_POSTGRESQL_PASSWORD}"

terraform init
tf_apply_rc=0
terraform apply -auto-approve || tf_apply_rc=$?

# Archive state on success and failure so deprovision can destroy partial applies.
# Exclude auth.json from the shared archive; deprovision remounts the secret.
archive_terraform_state

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

QUAY_DB_PUBLIC_IP=$(terraform output -raw quay_db_public_ip)
echo "${QUAY_DB_PUBLIC_IP}" > "${SHARED_DIR}/gsql_db_public_ip"
echo "Google Cloud SQL provisioning completed"

# Extract SSL certificates
terraform output -raw db_latest_ca_cert >server-ca.pem
terraform output -raw client_key >client-key.pem
terraform output -raw client_cert >client-cert.pem
chmod 0600 client-key.pem

# Refresh archive with certificates for deploy steps; still exclude auth.json.
archive_terraform_state
cp client-cert.pem client-key.pem server-ca.pem "${SHARED_DIR}/"

# Install PostgreSQL extensions
mkdir -p extension && cd extension

cat >>variables.tf <<EOF
variable "quay_db_host" {
}

variable "db_username" {
}

variable "db_password" {
  sensitive = true
}

variable "expected_version" {
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
  expected_version = var.expected_version
  sslmode         = "require"
  connect_timeout = 15
}

resource "postgresql_extension" "pg_trgm" {
  name     = "pg_trgm"
  database = var.db_name
}
EOF

export TF_VAR_quay_db_host="${QUAY_DB_PUBLIC_IP}"
export TF_VAR_db_username="${GCP_POSTGRESQL_USERNAME}"
export TF_VAR_db_password="${GCP_POSTGRESQL_PASSWORD}"
export TF_VAR_expected_version="${EXPECTED_VERSION}"
export TF_VAR_db_name="${GCP_POSTGRESQL_DBNAME}"
export PGSSLCERT="../client-cert.pem"
export PGSSLKEY="../client-key.pem"
export PGSSLROOTCERT="../server-ca.pem"

terraform init
terraform apply -auto-approve

echo "PostgreSQL extensions installed successfully"

# URL-encode credentials for DB_URI; leave host/db unencoded.
DB_URI_USER=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${GCP_POSTGRESQL_USERNAME}")
DB_URI_PASS=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${GCP_POSTGRESQL_PASSWORD}")

# Generate Quay configuration fragment for GCP SQL database with SSL
cat > "${SHARED_DIR}/quay-database-gcp-sql-config.yaml" <<EOF
DB_CONNECTION_ARGS:
  autorollback: true
  sslmode: verify-ca
  sslrootcert: /.postgresql/root.crt
  sslcert: /.postgresql/postgresql.crt
  sslkey: /.postgresql/postgresql.key
  threadlocals: true
DB_URI: postgresql://${DB_URI_USER}:${DB_URI_PASS}@${QUAY_DB_PUBLIC_IP}:5432/${GCP_POSTGRESQL_DBNAME}?sslmode=verify-ca&sslcert=/.postgresql/postgresql.crt&sslkey=/.postgresql/postgresql.key&sslrootcert=/.postgresql/root.crt
EOF

echo "Google Cloud SQL provisioning completed successfully"
echo "Database details, certificates, and config fragment saved to SHARED_DIR"
