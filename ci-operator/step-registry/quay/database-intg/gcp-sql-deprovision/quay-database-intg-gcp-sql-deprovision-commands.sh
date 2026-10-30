#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deprovision Google Cloud SQL PostgreSQL database created by
# quay-database-intg-gcp-sql. Destroys from the archived Terraform state;
# when the archive is missing, imports the instance by its persisted
# SHARED_DIR identifiers and destroys it. Uses the gcp-quay-qe cluster
# profile's service account and project - the same credentials the
# provisioning step creates resources with.

QUAY_GCP_SQL_TERRAFORM_PACKAGE="QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz"

echo "Deprovisioning Google Cloud SQL PostgreSQL database..."

# The cluster's GCP project and service-account key from the gcp-quay-qe
# cluster profile (same source as the provisioning step), with the
# project/region the provisioner persisted to SHARED_DIR as fallbacks for
# the identifier-import path.
if [[ ! -r "${CLUSTER_PROFILE_DIR}/gce.json" ]]; then
  echo "ERROR: gce.json not found in ${CLUSTER_PROFILE_DIR}; cannot authenticate." >&2
  exit 1
fi
GCP_PROJECT=""
if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_PROJECT" ]]; then
  GCP_PROJECT="$(cat "${SHARED_DIR}/QUAY_DB_GCP_PROJECT")"
fi
if [[ -z "${GCP_PROJECT}" && -r "${CLUSTER_PROFILE_DIR}/openshift_gcp_project" ]]; then
  GCP_PROJECT="$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")"
fi
GCP_SQL_REGION=""
if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_REGION" ]]; then
  GCP_SQL_REGION="$(cat "${SHARED_DIR}/QUAY_DB_GCP_REGION")"
fi
if [[ -z "${GCP_SQL_REGION}" ]]; then
  GCP_SQL_REGION="${LEASED_RESOURCE:-}"
  [[ "${GCP_SQL_REGION}" =~ ^[a-z]+-[a-z]+[0-9]$ ]] || GCP_SQL_REGION=""
fi

mkdir -p terraform_quay_gcp_sql && cd terraform_quay_gcp_sql

has_db_identifiers=false
if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME" || -f "${SHARED_DIR}/gsql_db_public_ip" || -s "${SHARED_DIR}/client-cert.pem" ]]; then
  has_db_identifiers=true
fi

# Fallback for a missing/lost Terraform archive: reconstruct a minimal config
# and terraform-import the instance by its persisted name, then destroy it.
# Mirrors the identifier fallback in the AWS/Azure deprovision steps. Deleting
# the instance cascades its databases, users, and client certificates.
cleanup_by_identifiers() {
  local instance_name=""
  if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME" ]]; then
    instance_name="$(cat "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME")"
  fi
  if [[ -z "${instance_name}" || -z "${GCP_PROJECT}" || -z "${GCP_SQL_REGION}" ]]; then
    echo "ERROR: DB instance, project, or region identifier missing; cannot import." >&2
    return 1
  fi
  echo "Reconstructing Terraform config and importing instance ${instance_name} for cleanup..." >&2
  cat >create_gcp_sql.tf <<EOF
provider "google" {
  credentials = file("auth.json")
  project = "${GCP_PROJECT}"
  region  = "${GCP_SQL_REGION}"
}

# Minimal stand-in for the provisioning config: after terraform import the
# resource values come from the state, so only the identity matters.
resource "google_sql_database_instance" "instance" {
  name             = "${instance_name}"
  database_version = "POSTGRES_17"
  region           = "${GCP_SQL_REGION}"
  deletion_protection = false
}
EOF
  cp "${CLUSTER_PROFILE_DIR}/gce.json" auth.json
  terraform init || return 1
  # Tolerant import: a never-created or already-deleted instance must not
  # abort cleanup (the state check below skips destroy when it failed).
  terraform import google_sql_database_instance.instance "${GCP_PROJECT}/${instance_name}" || true
  if ! terraform state list | grep -q google_sql_database_instance; then
    echo "Instance ${instance_name} not found in project ${GCP_PROJECT}; nothing to clean up."
    return 0
  fi
  terraform destroy -auto-approve
}

if [[ ! -f "${SHARED_DIR}/${QUAY_GCP_SQL_TERRAFORM_PACKAGE}" ]]; then
  if [[ "${has_db_identifiers}" == true ]]; then
    echo "${QUAY_GCP_SQL_TERRAFORM_PACKAGE} missing from SHARED_DIR but GCP SQL identifiers are present; falling back to identifier-based cleanup." >&2
    if ! cleanup_by_identifiers; then
      echo "ERROR: GCP SQL Terraform archive missing and identifier cleanup failed;" >&2
      echo "       the instance may need manual cleanup." >&2
      exit 1
    fi
    echo "Google Cloud SQL database destroyed successfully via identifier fallback"
    exit 0
  fi
  echo "No GCP SQL Terraform archive or identifiers found; nothing to deprovision."
  exit 0
fi

cp "${SHARED_DIR}/${QUAY_GCP_SQL_TERRAFORM_PACKAGE}" .
tar -xzvf ${QUAY_GCP_SQL_TERRAFORM_PACKAGE} && ls

# Copy the service-account key from the cluster profile
cp "${CLUSTER_PROFILE_DIR}/gce.json" auth.json

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
