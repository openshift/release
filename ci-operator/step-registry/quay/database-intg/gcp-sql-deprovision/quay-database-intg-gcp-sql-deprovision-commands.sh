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

# The cluster network the database's Private Service Access peering lives in:
# persisted by the provisioning step, derived from the installer's metadata
# otherwise. The peering must be destroyed before ipi-deprovision deletes
# the network, so the identifier fallback cleans it up too.
GCP_CLUSTER_NETWORK=""
if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_NETWORK" ]]; then
  GCP_CLUSTER_NETWORK="$(cat "${SHARED_DIR}/QUAY_DB_GCP_NETWORK")"
fi
if [[ -z "${GCP_CLUSTER_NETWORK}" && -r "${SHARED_DIR}/metadata.json" ]]; then
  GCP_CLUSTER_NETWORK="$(jq -r .infraID "${SHARED_DIR}/metadata.json" 2>/dev/null || true)-network"
fi

mkdir -p terraform_quay_gcp_sql && cd terraform_quay_gcp_sql

has_db_identifiers=false
if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME" || -f "${SHARED_DIR}/gsql_db_private_ip" || -s "${SHARED_DIR}/client-cert.pem" ]]; then
  has_db_identifiers=true
fi

# Fallback for a missing/lost Terraform archive: reconstruct a minimal config
# and terraform-import the instance by its persisted name, then destroy it.
# Mirrors the identifier fallback in the AWS/Azure deprovision steps. Deleting
# the instance cascades its databases, users, and client certificates, and
# the Private Service Access range/peering are removed with it - the peering
# must be gone before ipi-deprovision deletes the cluster network.
cleanup_by_identifiers() {
  local instance_name=""
  if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME" ]]; then
    instance_name="$(cat "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME")"
  fi
  if [[ -z "${instance_name}" || -z "${GCP_PROJECT}" || -z "${GCP_SQL_REGION}" ]]; then
    echo "ERROR: DB instance, project, or region identifier missing; cannot import." >&2
    return 1
  fi
  if [[ -z "${GCP_CLUSTER_NETWORK}" ]]; then
    echo "ERROR: cluster network name unknown (no QUAY_DB_GCP_NETWORK file and no metadata.json);" >&2
    echo "       cannot clean up the Private Service Access peering, which may block the" >&2
    echo "       installer's network deletion and need manual removal." >&2
    return 1
  fi
  echo "Reconstructing Terraform config and importing instance ${instance_name} for cleanup..." >&2
  cat >create_gcp_sql.tf <<EOF
provider "google" {
  credentials = file("auth.json")
  project = "${GCP_PROJECT}"
  region  = "${GCP_SQL_REGION}"
}

# Minimal stand-ins for the provisioning config: after terraform import the
# resource values come from the state, so only the identity matters. The
# Private Service Access range and peering are declared so their imported
# state can be destroyed; the peering removal clears the way for the
# installer's network deletion.
resource "google_sql_database_instance" "instance" {
  name             = "${instance_name}"
  database_version = "POSTGRES_17"
  region           = "${GCP_SQL_REGION}"
  deletion_protection = false
  # Destroy order: the instance must go before the peering/range it uses.
  depends_on = [google_service_networking_connection.private_service_access]
}

resource "google_compute_global_address" "private_ip_range" {
  name          = "${instance_name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
}

resource "google_service_networking_connection" "private_service_access" {
  network                 = "projects/${GCP_PROJECT}/global/networks/${GCP_CLUSTER_NETWORK}"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}
EOF
  cp "${CLUSTER_PROFILE_DIR}/gce.json" auth.json
  terraform init || return 1
  # Import by persisted identifiers. Only a confirmed "remote object does not
  # exist" counts as nothing to clean up: any other import failure (transient
  # API error, bad credentials) must fail the step so manual cleanup is
  # flagged instead of silently reported as success.
  local import_log
  import_log="$(mktemp)"
  import_resource() {
    local address="$1" id="$2"
    if terraform import "${address}" "${id}" >"${import_log}" 2>&1; then
      echo "Imported ${address} (${id})."
    elif grep -qE "Cannot import non-existent remote object|googleapi: Error 404" "${import_log}"; then
      echo "${address} (${id}) not found; nothing to clean up."
    else
      echo "ERROR: terraform import failed for ${address}; it may still exist and need manual cleanup:" >&2
      cat "${import_log}" >&2
      rm -f "${import_log}"
      return 1
    fi
  }
  import_resource google_sql_database_instance.instance "${GCP_PROJECT}/${instance_name}" || { rm -f "${import_log}"; return 1; }
  import_resource google_compute_global_address.private_ip_range "projects/${GCP_PROJECT}/global/addresses/${instance_name}-psa" || { rm -f "${import_log}"; return 1; }
  import_resource google_service_networking_connection.private_service_access "projects/${GCP_PROJECT}/global/networks/${GCP_CLUSTER_NETWORK}:servicenetworking.googleapis.com" || { rm -f "${import_log}"; return 1; }
  rm -f "${import_log}"
  # A failing state list must not be read as an empty state.
  local state_list
  if ! state_list="$(terraform state list)"; then
    echo "ERROR: terraform state list failed after import." >&2
    return 1
  fi
  if [[ -z "${state_list}" ]]; then
    echo "Instance, range, and peering not found; nothing to clean up."
    return 0
  fi
  # Destroy whatever imported: the instance (if present) first, then the
  # Private Service Access peering and range. Destroying the connection
  # while the instance still exists would fail, so keep the declared
  # dependency order and let terraform sequence it.
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
if ! state_list="$(terraform state list)"; then
  # The archive can be config-only (apply interrupted before Terraform
  # wrote state): with a persisted instance identifier, fall through to
  # identifier cleanup instead of aborting; without one there is nothing
  # to fall back to.
  if [[ -f "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME" ]]; then
    echo "terraform state list failed on the archived state; treating it as empty." >&2
    state_list=""
  else
    echo "ERROR: terraform state list failed on the archived state." >&2
    exit 1
  fi
fi
echo "${state_list}"

# The archive can predate the instance: a step that died during apply still
# archives an empty/partial state via its EXIT trap, while GCP may be
# mid-creating the instance. When the state has no instance but the
# persisted identifier exists, fall back to identifier-based cleanup so the
# in-flight instance is still deleted.
if ! grep -q google_sql_database_instance <<<"${state_list}" \
   && [[ -f "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME" ]]; then
  echo "Archived state has no instance; falling back to identifier-based cleanup." >&2
  if ! cleanup_by_identifiers; then
    echo "ERROR: identifier cleanup failed; the instance may need manual cleanup." >&2
    exit 1
  fi
  echo "Google Cloud SQL database destroyed successfully via identifier fallback"
  exit 0
fi

# Workaround for known terraform-provider-google destroy issues (both hit in
# QE before, see the original quay-tests/resource/deprovisioning/gcp-sql step):
# 1. "failed to delete user ... cannot be dropped because some objects depend
#    on it" - https://github.com/hashicorp/terraform-provider-google/issues/3820
# 2. "failed to delete database ... is being accessed by other users" - the
#    Quay pods are still running when this post step executes and keep open
#    connection pools to the external database.
# Removing the user/database from state lets the instance deletion cascade
# everything: dropping a whole instance ignores active sessions and object
# ownership, unlike individual user/database deletion. Exact-address matches
# against the captured state_list: an unanchored grep would also match
# google_sql_database_instance.instance (so a state holding only the instance
# would fail the rm under errexit and leak it), and a grep -q pipeline can
# SIGPIPE terraform under pipefail.
if grep -qx 'google_sql_user.users' <<<"${state_list}"; then
  terraform state rm google_sql_user.users
fi
if grep -qx 'google_sql_database.database' <<<"${state_list}"; then
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
