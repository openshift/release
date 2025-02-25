#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

GCP_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
GCP_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
GCP_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)

QUAY_GCP_SQL_TERRAFORM_PACKAGE="QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz"
mkdir -p QUAY_GCPSQL && cd QUAY_GCPSQL
#Copy GCP auth.json from mounted secret to current directory
cp /var/run/quay-qe-gcp-secret/auth.json .

echo "Google Cloud SQL Database version is ${DB_VERSION}"

cat >>variables.tf <<EOF
variable "region" {
default  = "us-central1"
}

variable "tier" {
  default = "db-custom-2-7680"  # Choose an appropriate machine type (2 vCPUs, 7.5GB RAM)
}


variable "database_version" {
  default = "${DB_VERSION}"  # PostgreSQL 17 by default
}

variable "database_name" {
  default = "${GCP_POSTGRESQL_DBNAME}"  
}

variable "database_username" {
  default = "${GCP_POSTGRESQL_USERNAME}"
}

variable "database_password" {
  default = "${GCP_POSTGRESQL_PASSWORD}"
}

EOF

cat >>create_gcp_sql.tf <<EOF
provider "google" {
  credentials = file("auth.json")
  project = "openshift-qe"  # dedicated project ID
  region  = var.region
}

resource "google_sql_database_instance" "instance" {
  name             = "quay-postgres-prow$RANDOM"
  database_version = var.database_version
  region           = var.region
  
  # If not set or set to true, will NOT be detroied by Terraform
  deletion_protection = false

  settings {
    tier = var.tier
    edition = "ENTERPRISE"
    availability_type = "ZONAL"  # Use "ZONAL" for single-zone deployments, "REGIONAL" for multi-zone deployments

    disk_size         = 10          # GB
    disk_type         = "PD_SSD"    # Options: "PD_HDD" or "PD_SSD"

    ip_configuration {
      ipv4_enabled    = true

      # The following SSL enforcement options only allow connections encrypted with SSL/TLS and with valid client certificates.
      # https://cloud.google.com/sql/docs/postgres/admin-api/rest/v1beta4/instances#ipconfiguration
      ssl_mode = "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
      authorized_networks {
        name  = "allow-all"
        value = "0.0.0.0/0"  # WARNING: Allows all IPs. Restrict this in production.
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

#https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_ssl_cert#private_key-1
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
#https://cloud.google.com/sql/docs/postgres/configure-ssl-instance#terraform_2
data "google_sql_ca_certs" "ca_certs" {
  instance = google_sql_database_instance.instance.name
}

locals {
    furthest_expiration_time = reverse(sort([for k, v in data.google_sql_ca_certs.ca_certs.certs : v.expiration_time]))[0]
    latest_ca_cert           = [for v in data.google_sql_ca_certs.ca_certs.certs : v.cert if v.expiration_time == local.furthest_expiration_time]
}

output "db_latest_ca_cert" {
  description = "Latest CA certificate used by the primary database server"
  
  # https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/sql_ca_certs
  # the official is 
  # value       = local.latest_ca_cert
  # but output is still in a list [...], to simplify, fetch the first and only one directly
  value       = local.latest_ca_cert[0]
  sensitive   = true
}
EOF

terraform init
terraform apply -auto-approve

QUAY_DB_PUBLIC_IP=$(terraform output quay_db_public_ip | tr -d '""' | tr -d '\n')
echo "GSQL DB IP is $QUAY_DB_PUBLIC_IP"

#The -raw flag forces Terraform to remove <<EOT and EOT markers
terraform output -raw db_latest_ca_cert >server-ca.pem
terraform output -raw client_key >client-key.pem
terraform output -raw client_cert >client-cert.pem
chmod 0600 client-key.pem

# Copy certs to SHARED_DIR
function copyCerts() {
  tar -cvzf "$QUAY_GCP_SQL_TERRAFORM_PACKAGE" --exclude=".terraform" *
  echo "Copy Google Cloud SQL terraform tf files"
  cp "$QUAY_GCP_SQL_TERRAFORM_PACKAGE" "${SHARED_DIR}"

  #copy for create secret bundle
  cp client-cert.pem client-key.pem server-ca.pem "${SHARED_DIR}"
  echo "$QUAY_DB_PUBLIC_IP" >"${SHARED_DIR}"/gsql_db_public_ip

}

#install extension
function install_extension() {
  mkdir -p extension && cd extension

  cat >>variables.tf <<EOF
variable "quay_db_host" {
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
  username        = "${GCP_POSTGRESQL_USERNAME}"
  password        = "${GCP_POSTGRESQL_PASSWORD}"
  expected_version = "17"
  sslmode         = "require"
  connect_timeout = 15
}

resource "postgresql_extension" "pg_trgm" {
  name     = "pg_trgm"
  database = "${GCP_POSTGRESQL_DBNAME}"
}
EOF

  export TF_VAR_quay_db_host=$QUAY_DB_PUBLIC_IP
  export PGSSLCERT="../client-cert.pem"
  export PGSSLKEY="../client-key.pem"
  export PGSSLROOTCERT="../server-ca.pem"

  terraform init
  terraform apply -auto-approve

}

copyCerts || true
install_extension || true
echo "Google Cloud SQL instance created successfully"
