#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deprovision Azure Database for PostgreSQL Flexible Server created by
# quay-database-intg-azure-postgres. Uses step-specific SHARED_DIR names so this
# never destroys blob Terraform state (quay-deploy-azure-blob's terraform.tgz).
# The database lives in the OpenShift cluster's resource group; this step only
# ever destroys the flexible server itself - never the resource group, which
# the installer owns and deletes (cascading any leftover DB resources) during
# ipi-deprovision-deprovision.

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

QUAY_DB_AZURE_SERVER=""
if [[ -f "${SHARED_DIR}/QUAY_DB_AZURE_SERVER" ]]; then
  QUAY_DB_AZURE_SERVER=$(cat "${SHARED_DIR}/QUAY_DB_AZURE_SERVER")
fi

# Cluster region persisted by the provisioning step. Destroy does not use the
# value (it deletes by resource ID), but Terraform requires the variable to be
# set; fall back to any valid location when the file is absent.
QUAY_DB_AZURE_REGION="eastus"
if [[ -f "${SHARED_DIR}/QUAY_DB_AZURE_REGION" ]]; then
  QUAY_DB_AZURE_REGION=$(cat "${SHARED_DIR}/QUAY_DB_AZURE_REGION")
fi

# Fallback for a missing/lost Terraform archive: reconstruct a minimal config
# and terraform-import the server by its identifiers, then destroy it. Mirrors
# the identifier fallback in quay-database-intg-aws-rds-deprovision. Never uses
# `az group delete`: the image has no az CLI, and the DB resource group is the
# cluster's RG, which must never be deleted here.
cleanup_by_identifiers() {
  if [[ -z "${QUAY_DB_AZURE_RESOURCE_GROUP}" || -z "${QUAY_DB_AZURE_SERVER}" ]]; then
    echo "ERROR: DB server or resource-group identifier missing; cannot import." >&2
    return 1
  fi
  echo "Reconstructing Terraform config and importing server ${QUAY_DB_AZURE_SERVER} for cleanup..." >&2
  cat >variables.tf <<EOF
variable "resource_group_name" {
}

variable "location" {
}

variable "server_name" {
}

variable "postgres_version" {
  default = "17"
}

variable "db_name" {
  default = "quay"
}

variable "db_username" {
  default = "quayuser"
}

variable "db_password" {
  sensitive = true
  default   = "dummypass"
}
EOF
  cat >create_azure_postgres.tf <<EOF
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.46"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_postgresql_flexible_server" "quay" {
  name                   = var.server_name
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.postgres_version
  administrator_login    = var.db_username
  administrator_password = var.db_password
  sku_name               = "GP_Standard_D4ds_v5"
  storage_mb             = 1048576
  zone                   = "1"

  authentication {
    password_auth_enabled = true
  }
}
EOF
  export TF_VAR_resource_group_name="${QUAY_DB_AZURE_RESOURCE_GROUP}"
  export TF_VAR_server_name="${QUAY_DB_AZURE_SERVER}"
  export TF_VAR_location="${QUAY_DB_AZURE_REGION}"
  terraform init || return 1
  # Tolerant import: a never-created or already-deleted server must not abort
  # cleanup (the state rm below is skipped when the import failed).
  terraform import azurerm_postgresql_flexible_server.quay \
    "/subscriptions/${ARM_SUBSCRIPTION_ID}/resourceGroups/${QUAY_DB_AZURE_RESOURCE_GROUP}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${QUAY_DB_AZURE_SERVER}" || true
  if ! terraform state list | grep -q azurerm_postgresql_flexible_server; then
    echo "Server ${QUAY_DB_AZURE_SERVER} not found in ${QUAY_DB_AZURE_RESOURCE_GROUP}; nothing to clean up."
    return 0
  fi
  terraform destroy -auto-approve
}

has_db_identifiers=false
if [[ -n "${QUAY_DB_AZURE_RESOURCE_GROUP}" || -f "${SHARED_DIR}/QUAY_DB_AZURE_SERVER" || -f "${SHARED_DIR}/QUAY_AZURE_SERVER_FQDN" ]]; then
  has_db_identifiers=true
fi

if [[ ! -f "${SHARED_DIR}/${QUAY_DB_AZURE_TF_ARCHIVE}" ]]; then
  if [[ "${has_db_identifiers}" == true ]]; then
    echo "WARNING: ${QUAY_DB_AZURE_TF_ARCHIVE} missing from SHARED_DIR but DB identifiers are present; attempting identifier-based cleanup." >&2
    if ! cleanup_by_identifiers; then
      echo "ERROR: Azure DB Terraform archive missing and identifier cleanup failed;" >&2
      echo "       the installer's cluster resource-group deletion is the backstop." >&2
      exit 1
    fi
    echo "Azure Database for PostgreSQL destroyed successfully via identifier fallback"
    exit 0
  fi
  echo "No Azure DB Terraform archive or identifiers found; nothing to deprovision."
  exit 0
fi

cp "${SHARED_DIR}/${QUAY_DB_AZURE_TF_ARCHIVE}" .
tar -xzvf "${QUAY_DB_AZURE_TF_ARCHIVE}" && ls

echo "Destroying Azure Database for PostgreSQL..."

export TF_VAR_resource_group_name="${QUAY_DB_AZURE_RESOURCE_GROUP}"
export TF_VAR_location="${QUAY_DB_AZURE_REGION}"
export TF_VAR_server_name="${QUAY_DB_AZURE_SERVER:-quaypostgresql}"
export TF_VAR_db_name="quay"
export TF_VAR_db_username="quayuser"
export TF_VAR_db_password="dummypass"

terraform init
terraform state list

# Quay pods are still running when this post step executes and keep open
# connection pools to the external database; dropping an individual database
# can fail on active sessions ("database is being accessed by other users",
# same failure class as the GCP SQL deprovision). Removing the database from
# state lets the server/resource-group deletion cascade it - deleting the
# server force-drops everything regardless of active sessions.
if terraform state list | grep -q "azurerm_postgresql_flexible_server_database"; then
  terraform state rm azurerm_postgresql_flexible_server_database.quay
fi

tf_destroy_rc=0
terraform destroy -auto-approve || tf_destroy_rc=$?

if [[ "${tf_destroy_rc}" -ne 0 ]]; then
  echo "ERROR: terraform destroy failed with exit code ${tf_destroy_rc}." >&2
  echo "       The installer deletes the cluster resource group (and with it any" >&2
  echo "       leftover database resources) during ipi-deprovision-deprovision." >&2
  exit "${tf_destroy_rc}"
fi

echo "Azure Database for PostgreSQL destroyed successfully"
