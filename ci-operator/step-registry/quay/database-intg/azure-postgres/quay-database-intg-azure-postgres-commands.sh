#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Provision Azure Database for PostgreSQL Flexible Server for Quay.
# Outputs database connection details and config fragment to SHARED_DIR.
# Uses step-specific SHARED_DIR names so quay-deploy-azure-blob cannot overwrite
# the DB Terraform state (deploy writes SHARED_DIR/terraform.tgz). The server
# is created in the OpenShift cluster's resource group - the same RG the
# installer created and quay-deploy-azure-blob creates the storage account in -
# so the database is co-located with the cluster and the installer's RG
# deletion at teardown is a cleanup backstop. The RG itself is never created
# or destroyed by this step's Terraform.

QUAY_DB_AZURE_TF_ARCHIVE="quay-db-azure-postgres-terraform.tgz"

echo "Provisioning Azure Database for PostgreSQL Flexible Server (version ${POSTGRESQL_VERSION})..."

# Get Azure credentials from cluster profile (same as quay-deploy-azure-blob)
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ ! -r "${AZURE_AUTH_LOCATION}" ]]; then
  echo "ERROR: ${AZURE_AUTH_LOCATION} not found or unreadable." >&2
  echo "       This step requires the azure-quay-qe cluster profile, whose" >&2
  echo "       osServicePrincipal.json provides the credentials to create Azure Database for PostgreSQL." >&2
  exit 1
fi

# Export ARM_* so the azurerm provider can authenticate without secrets in .tf files.
ARM_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")
ARM_TENANT_ID=$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")
ARM_CLIENT_SECRET=$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")
ARM_CLIENT_ID=$(jq -r .clientId "${AZURE_AUTH_LOCATION}")
export ARM_SUBSCRIPTION_ID ARM_TENANT_ID ARM_CLIENT_SECRET ARM_CLIENT_ID

# The cluster's resource group and region, discovered the same way
# quay-deploy-azure-blob discovers them (infrastructure/cluster status). This
# co-locates the database with the cluster - a hardcoded "East US" location
# put it in a different region from the leased cluster (westus2), adding
# cross-region latency to every query. There is no fallback: without the
# cluster RG the database cannot be co-located, and the test phase is broken
# anyway if the cluster API is unreachable.
QUAY_DB_AZURE_RESOURCE_GROUP=$(oc get infrastructure cluster \
  -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' 2>/dev/null || true)
if [[ -z "${QUAY_DB_AZURE_RESOURCE_GROUP}" ]]; then
  echo "ERROR: could not determine the cluster's Azure resource group from" >&2
  echo "       infrastructure/cluster .status.platformStatus.azure.resourceGroupName." >&2
  exit 1
fi
CLUSTER_AZURE_REGION=$(oc get infrastructure cluster \
  -o jsonpath='{.status.platformStatus.azure.region}' 2>/dev/null || true)
if [[ -z "${CLUSTER_AZURE_REGION}" ]]; then
  echo "ERROR: could not determine the cluster's Azure region from" >&2
  echo "       infrastructure/cluster .status.platformStatus.azure.region." >&2
  exit 1
fi
echo "Cluster resource group: ${QUAY_DB_AZURE_RESOURCE_GROUP}, region: ${CLUSTER_AZURE_REGION}"

QUAY_DB_AZURE_SERVER="quaypostgresql$RANDOM"
# Generate per-job database credentials: nothing static to rotate or leak.
# Password is letters+digits only: upper+lower+digits meets the Flexible
# Server 3-of-4 character-category rule and keeps DB_URI quoting simple;
# it is never echoed to logs.
QUAY_AZURE_DB_NAME="quaydb${RANDOM}"
QUAY_AZURE_DB_USERNAME="quayuser${RANDOM}"
QUAY_AZURE_DB_PASSWORD="Quayci$(python3 -c 'import secrets; print(secrets.token_hex(12))')Az9"

# Create Terraform directory for Azure Database
mkdir -p terraform_azure_postgres && cd terraform_azure_postgres
# Pin the DB dir by absolute path for the EXIT trap below: this script later
# cds into terraform_install_extension, and a trap that archives the CWD
# overwrote the DB state archive with the extension files, breaking deprovision.
TF_AZURE_DB_DIR="$(pwd)"

archive_terraform_state() {
  # Best-effort: timeout/kill may interrupt mid-apply; still try to leave destroyable state.
  # Always archives the DB dir (never the CWD). The tarball is built in a
  # temp dir so it never contains itself, and is only copied to SHARED_DIR
  # when the tar succeeds, so a failed re-archive cannot clobber a good one.
  local archive_tmp
  archive_tmp="$(mktemp -d)/${QUAY_DB_AZURE_TF_ARCHIVE}"
  if (cd "${TF_AZURE_DB_DIR}" && tar -cvzf "${archive_tmp}" --exclude=".terraform" ./*); then
    cp -f "${archive_tmp}" "${SHARED_DIR}/" || true
  fi
}
trap archive_terraform_state EXIT

cat >>variables.tf <<EOF
variable "resource_group_name" {
}

variable "location" {
}

variable "server_name" {
}

variable "postgres_version" {
  default = "${POSTGRESQL_VERSION}"
}

variable "db_name" {
}

variable "db_username" {
}

variable "db_password" {
  sensitive = true
}
EOF

cat >>create_azure_postgres.tf <<EOF
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      # Stay on the 4.x line: PostgreSQL 17 on Flexible Server needs >= 4.46,
      # but the open-ended ">= 4.46.0" constraint resolved to azurerm 5.9.0,
      # whose flexible-server create returns "ParameterOutOfRange: The value
      # of the 'Version' should be in: []" (build 2110619773975924736).
      version = "~> 4.46"
    }
  }
}

provider "azurerm" {
  features {}
}

# No azurerm_resource_group resource: the server goes into the OpenShift
# cluster's pre-existing resource group, referenced by name only. Terraform
# must never manage (and especially never destroy) that RG.
resource "azurerm_postgresql_flexible_server" "quay" {
  name                   = var.server_name
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.postgres_version
  administrator_login    = var.db_username
  administrator_password = var.db_password
  # 4 vCPU / 16 GiB general purpose, matching the AWS (db.m5.xlarge) and GCP
  # (db-custom-4-15360) lanes. The burstable B_Standard_B1ms (1 vCPU) is too
  # small for the full Playwright e2e suite.
  sku_name               = "GP_Standard_D4ds_v5"
  # 1 TiB maps to the ~5000-IOPS storage tier, at or above the AWS gp3
  # 3000-IOPS baseline that passes; 32 GiB (~120 IOPS) starved the suite on
  # GCP (build 2110398453279363072: 2h15m e2e timeout on DB-bound pages).
  storage_mb             = 1048576
  backup_retention_days  = 7
  geo_redundant_backup_enabled = false
  zone                   = "1"

  authentication {
    password_auth_enabled = true
  }

  tags = {
    Name = "Quay PostgreSQL Database"
  }
}

resource "azurerm_postgresql_flexible_server_database" "quay" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.quay.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_all" {
  name             = "AllowAllIPs"
  server_id        = azurerm_postgresql_flexible_server.quay.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.quay.id
  value     = "PG_TRGM"
}

output "server_fqdn" {
  value = azurerm_postgresql_flexible_server.quay.fqdn
}

output "server_name" {
  value = azurerm_postgresql_flexible_server.quay.name
}

output "db_name" {
  value = azurerm_postgresql_flexible_server_database.quay.name
}

output "db_username" {
  value = var.db_username
}

output "db_password" {
  value = var.db_password
  sensitive = true
}
EOF

export TF_VAR_resource_group_name="${QUAY_DB_AZURE_RESOURCE_GROUP}"
export TF_VAR_location="${CLUSTER_AZURE_REGION}"
export TF_VAR_server_name="${QUAY_DB_AZURE_SERVER}"
export TF_VAR_db_name="${QUAY_AZURE_DB_NAME}"
export TF_VAR_db_username="${QUAY_AZURE_DB_USERNAME}"
export TF_VAR_db_password="${QUAY_AZURE_DB_PASSWORD}"

# Persist DB-only identifiers. QUAY_DB_AZURE_RESOURCE_GROUP now holds the
# cluster RG (same value quay-deploy-azure-blob later writes to its own
# QUAY_AZURE_RESOURCE_GROUP key); keep the step-specific key so the two steps
# stay decoupled.
echo "${QUAY_DB_AZURE_RESOURCE_GROUP}" > "${SHARED_DIR}/QUAY_DB_AZURE_RESOURCE_GROUP"
echo "${CLUSTER_AZURE_REGION}" > "${SHARED_DIR}/QUAY_DB_AZURE_REGION"
echo "${QUAY_DB_AZURE_SERVER}" > "${SHARED_DIR}/QUAY_DB_AZURE_SERVER"

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

QUAY_AZURE_SERVER_FQDN=$(terraform output -raw server_fqdn)
echo "${QUAY_AZURE_SERVER_FQDN}" > "${SHARED_DIR}/QUAY_AZURE_SERVER_FQDN"
echo "Azure PostgreSQL Flexible Server provisioning completed"

# azure.extensions only allowlists; Quay requires pg_trgm to actually exist.
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
      source  = "cyrilgdn/postgresql"
      version = "1.22.0"
    }
  }
}

provider "postgresql" {
  host             = var.quay_db_host
  username         = var.db_username
  password         = var.db_password
  expected_version = var.engine_version
  sslmode          = "require"
  connect_timeout  = 15
}

resource "postgresql_extension" "pg_trgm" {
  name     = "pg_trgm"
  database = var.db_name
}
EOF

export TF_VAR_quay_db_host="${QUAY_AZURE_SERVER_FQDN}"
export TF_VAR_db_username="${QUAY_AZURE_DB_USERNAME}"
export TF_VAR_db_password="${QUAY_AZURE_DB_PASSWORD}"
export TF_VAR_engine_version="${POSTGRESQL_VERSION}"
export TF_VAR_db_name="${QUAY_AZURE_DB_NAME}"
terraform init
terraform apply -auto-approve

echo "PostgreSQL extensions installed successfully"

# URL-encode credentials for DB_URI; Flexible Server uses username without @server suffix.
DB_URI_USER=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${QUAY_AZURE_DB_USERNAME}")
DB_URI_PASS=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${QUAY_AZURE_DB_PASSWORD}")

# Generate Quay configuration fragment for Azure Database
cat > "${SHARED_DIR}/quay-database-azure-postgres-config.yaml" <<EOF
DB_CONNECTION_ARGS:
  autorollback: true
  threadlocals: true
  sslmode: require
DB_URI: postgresql://${DB_URI_USER}:${DB_URI_PASS}@${QUAY_AZURE_SERVER_FQDN}:5432/${QUAY_AZURE_DB_NAME}
EOF

echo "Azure Database for PostgreSQL provisioning completed successfully"
echo "Database details and config fragment saved to SHARED_DIR"
