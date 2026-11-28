#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Provision Google Cloud SQL PostgreSQL database for Quay.
# Outputs database connection details, SSL certificates, and config fragment
# to SHARED_DIR. Uses the gcp-quay-qe cluster profile's service account and
# project - the same credentials the cluster was installed with and
# quay-deploy-gcp-gcs creates the storage bucket with - so the database
# lands in the same project as the cluster infrastructure.

QUAY_GCP_SQL_TERRAFORM_PACKAGE="QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz"

# Generate per-job database credentials: nothing static to rotate or leak.
# Password is letters+digits only: upper+lower+digits meets provider
# complexity rules (e.g. Azure's 3-of-4 categories) and keeps DB_URI
# quoting simple; it is never echoed to logs.
GCP_POSTGRESQL_DBNAME="quaydb${RANDOM}"
GCP_POSTGRESQL_USERNAME="quayuser${RANDOM}"
GCP_POSTGRESQL_PASSWORD="Quayci$(python3 -c 'import secrets; print(secrets.token_hex(12))')Az9"

# Cloud SQL wants database_version in POSTGRES_<major> form.
DB_VERSION="POSTGRES_${POSTGRESQL_VERSION}"
# Explicit instance name, generated and persisted to SHARED_DIR before apply
# (see the identifiers block below): a step killed mid-apply would otherwise
# leave an instance whose name is only knowable from post-apply outputs.
# secrets.token_hex (same pattern as the password) keeps the name project-
# unique per job: bash $RANDOM is only 15 bits and Cloud SQL instance names
# must be unique per project.
QUAY_GCP_SQL_INSTANCE_NAME="quay-postgres-prow$(python3 -c 'import secrets; print(secrets.token_hex(6))')"

# The cluster's GCP project and service-account key from the gcp-quay-qe
# cluster profile - the same source quay-deploy-gcp-gcs uses.
if [[ ! -r "${CLUSTER_PROFILE_DIR}/gce.json" || ! -r "${CLUSTER_PROFILE_DIR}/openshift_gcp_project" ]]; then
  echo "ERROR: gce.json or openshift_gcp_project not found in ${CLUSTER_PROFILE_DIR}." >&2
  echo "       This step requires the gcp-quay-qe cluster profile, whose service" >&2
  echo "       account creates the Cloud SQL instance in the cluster's project." >&2
  exit 1
fi
GCP_PROJECT="$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")"

# Co-locate the database with the cluster. LEASED_RESOURCE carries the GCP
# region of the gcp-quay-qe quota slice the cluster was installed in (the
# same mechanism ipi-conf-gcp uses for install-config); fall back to the
# nodes' topology region label. A cross-region database adds tens of ms RTT
# to every query, which made the e2e suite blow per-test timeouts (rehearsal
# build 2110243574493745152: cluster in us-east1 vs SQL in us-central1,
# 318 failed tests, 2h step timeout). No silent default: a database in the
# wrong region measures latency, not Quay.
GCP_SQL_REGION="${LEASED_RESOURCE:-}"
if [[ ! "${GCP_SQL_REGION}" =~ ^[a-z]+-[a-z]+[0-9]$ ]]; then
  GCP_SQL_REGION=$(oc get nodes \
    -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null || true)
fi
if [[ ! "${GCP_SQL_REGION}" =~ ^[a-z]+-[a-z]+[0-9]$ ]]; then
  echo "ERROR: could not determine the cluster's GCP region from LEASED_RESOURCE" >&2
  echo "       or the nodes' topology.kubernetes.io/region label." >&2
  exit 1
fi

# The cluster's VPC: the installer names it <infraID>-network. The database
# gets a private IP in that network (Private Service Access) so pod-to-database
# traffic stays on the VPC. The public-IP path egresses through Cloud NAT,
# whose port exhaustion under the suite's connection churn drops SYNs - every
# connection paid a constant multi-second retransmit ladder (rehearsals
# 2117248575602692096 and 2117513887786995712, identical with 4 and 8 vCPU
# tiers), which throttled the e2e suite into its 2h timeout.
if [[ ! -r "${SHARED_DIR}/metadata.json" ]]; then
  echo "ERROR: ${SHARED_DIR}/metadata.json not found; cannot resolve the cluster network." >&2
  exit 1
fi
CLUSTER_INFRA_ID=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
if [[ -z "${CLUSTER_INFRA_ID}" || "${CLUSTER_INFRA_ID}" == "null" ]]; then
  echo "ERROR: could not read infraID from ${SHARED_DIR}/metadata.json." >&2
  exit 1
fi
CLUSTER_NETWORK_NAME="${CLUSTER_INFRA_ID}-network"

echo "Provisioning Google Cloud SQL PostgreSQL (${DB_VERSION}) in region ${GCP_SQL_REGION}..."

mkdir -p QUAY_GCPSQL && cd QUAY_GCPSQL
# Pin the Cloud SQL dir by absolute path for the EXIT trap below: this script
# later cds into the extension directory, and a trap that archives the CWD
# overwrote the DB state archive with the extension files, breaking deprovision.
TF_GCP_SQL_DIR="$(pwd)"

# Copy the service-account key into the Terraform dir; it stays excluded
# from every archive so credentials never enter SHARED_DIR.
cp "${CLUSTER_PROFILE_DIR}/gce.json" auth.json

archive_terraform_state() {
  # Best-effort: timeout/kill may interrupt mid-apply; still try to leave destroyable state.
  # Always archives the Cloud SQL dir (never the CWD). The tarball is built in
  # a temp dir so it never contains itself, and is only copied to SHARED_DIR
  # when the tar succeeds, so a failed re-archive cannot clobber a good one.
  local archive_tmp
  archive_tmp="$(mktemp -d)/${QUAY_GCP_SQL_TERRAFORM_PACKAGE}"
  if (cd "${TF_GCP_SQL_DIR}" && tar -cvzf "${archive_tmp}" --exclude=".terraform" --exclude="auth.json" ./*); then
    cp -f "${archive_tmp}" "${SHARED_DIR}/" || true
  fi
}
trap archive_terraform_state EXIT

cat >>variables.tf <<EOF
variable "region" {
  # Actual cluster region (see derivation above); baked into this file so the
  # deprovision step, which restores this archive, targets the same region.
  default  = "${GCP_SQL_REGION}"
}

variable "tier" {
  # 8 vCPUs / 30GB RAM. Doubled from 4 vCPUs while chasing the connection
  # throttling, which turned out to be Cloud NAT port exhaustion on the
  # public-IP path - the throttling was identical at 4 and 8 vCPUs - and is
  # addressed by the private IP. The AWS parity point is 4 vCPUs
  # (db.m5.xlarge); revisit this sizing once a private-IP rehearsal is green.
  default = "db-custom-8-30720"
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
data "google_compute_network" "cluster_network" {
  name = "${CLUSTER_NETWORK_NAME}"
}

# Private Service Access: reserve a range in the cluster's network and peer
# it with Google's service networking, which is what lets the Cloud SQL
# instance hold a private IP there. The peering and range are destroyed by
# the deprovision step before the installer deletes the network.
resource "google_compute_global_address" "private_ip_range" {
  name          = "${QUAY_GCP_SQL_INSTANCE_NAME}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  # Auto-selected by GCP to avoid overlapping the cluster's subnets.
  prefix_length = 20
  network       = data.google_compute_network.cluster_network.id
}

resource "google_service_networking_connection" "private_service_access" {
  network                 = data.google_compute_network.cluster_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  # Cloud SQL keeps producer resources for a while after an instance is
  # deleted, so deleting the connection right after can fail with "Producer
  # services ... are still using this connection", which would leave the
  # peering blocking the installer's network deletion. REMOVE_PEERING deletes
  # the connection and, if the API refuses for that reason, removes the VPC
  # peering so the network can be deleted.
  deletion_policy = "REMOVE_PEERING"
}

provider "google" {
  credentials = file("auth.json")
  project = "${GCP_PROJECT}"
  region  = var.region
}

resource "google_sql_database_instance" "instance" {
  name             = "${QUAY_GCP_SQL_INSTANCE_NAME}"
  database_version = var.database_version
  region           = var.region
  deletion_protection = false
  depends_on = [google_service_networking_connection.private_service_access]

  settings {
    tier = var.tier
    edition = "ENTERPRISE"
    availability_type = "ZONAL"

    # PD-SSD scales ~30 IOPS/GB: 10 GB gave ~300 IOPS and the full e2e suite
    # timed out at 2h15m with DB connection timeouts and 3s /health/instance
    # probes (build 2110398453279363072). 100 GB ≈ 3000 read/write IOPS, matching
    # the AWS gp3 baseline (3000 IOPS) that passes. Marginal cost ≈ $0.10/run.
    disk_size         = 100
    disk_type         = "PD_SSD"

    ip_configuration {
      # Private IP in the cluster's network (see the Private Service Access
      # resources above): no public IP, no Cloud NAT on the connection path.
      ipv4_enabled    = false
      ssl_mode = "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
      private_network = data.google_compute_network.cluster_network.id
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

output "quay_db_private_ip" {
  value = google_sql_database_instance.instance.private_ip_address
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
  sensitive = true
}
EOF

export TF_VAR_database_password="${GCP_POSTGRESQL_PASSWORD}"

# Persist DB-only identifiers early - before any apply runs - so deprovision
# can still clean up after a step killed mid-apply (when neither the state
# archive nor the post-apply outputs exist). Mirrors the AWS/Azure steps.
echo "${QUAY_GCP_SQL_INSTANCE_NAME}" > "${SHARED_DIR}/QUAY_DB_GCP_INSTANCE_NAME"
echo "${GCP_SQL_REGION}" > "${SHARED_DIR}/QUAY_DB_GCP_REGION"
echo "${GCP_PROJECT}" > "${SHARED_DIR}/QUAY_DB_GCP_PROJECT"
echo "${CLUSTER_NETWORK_NAME}" > "${SHARED_DIR}/QUAY_DB_GCP_NETWORK"

terraform init
tf_apply_rc=0
terraform apply -auto-approve || tf_apply_rc=$?

# Archive state on success and failure so deprovision can destroy partial applies.
# Exclude auth.json from the shared archive; deprovision remounts the profile.
archive_terraform_state

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

QUAY_DB_PRIVATE_IP=$(terraform output -raw quay_db_private_ip)
echo "${QUAY_DB_PRIVATE_IP}" > "${SHARED_DIR}/gsql_db_private_ip"
echo "Google Cloud SQL provisioning completed"

# Extract SSL certificates
terraform output -raw db_latest_ca_cert >server-ca.pem
terraform output -raw client_key >client-key.pem
terraform output -raw client_cert >client-cert.pem
chmod 0600 client-key.pem

# Refresh archive with certificates for deploy steps; still exclude auth.json.
archive_terraform_state
cp client-cert.pem client-key.pem server-ca.pem "${SHARED_DIR}/"

# Install the pg_trgm extension. The database is reachable only from inside
# the cluster's network (private IP): this step pod runs on the build farm
# and has no route to it, and Quay does not create the extension itself, so
# run CREATE EXTENSION from a pod in the cluster. The client certificates
# travel via a secret; psql refuses group/world-readable keys, so the pod
# copies the key to a 0600 file before connecting. The pod manifest carries
# the per-run database password, so it is written to a temp dir outside the
# Terraform archive and removed with the pod.
extension_pod_dir="$(mktemp -d)"
cleanup_extension_pod() {
  oc -n default delete pod quay-db-extension --ignore-not-found=true 2>/dev/null || true
  oc -n default delete secret quay-db-client-certs --ignore-not-found=true 2>/dev/null || true
  rm -rf "${extension_pod_dir}"
}
# Chain onto the state-archive trap: the pod and its secret must not outlive
# this step even when it fails.
trap 'archive_terraform_state; cleanup_extension_pod' EXIT

oc -n default create secret generic quay-db-client-certs \
  --from-file=client-cert.pem="${TF_GCP_SQL_DIR}/client-cert.pem" \
  --from-file=client-key.pem="${TF_GCP_SQL_DIR}/client-key.pem" \
  --from-file=server-ca.pem="${TF_GCP_SQL_DIR}/server-ca.pem"

cat >"${extension_pod_dir}/db-extension-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: quay-db-extension
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: registry.redhat.io/rhel9/postgresql-16
    command: ["/bin/bash", "-c", "--"]
    args:
    - |
      set -euo pipefail
      cp /certs/client-key.pem /tmp/client-key.pem
      chmod 0600 /tmp/client-key.pem
      PGPASSWORD="${GCP_POSTGRESQL_PASSWORD}" psql \
        "host=${QUAY_DB_PRIVATE_IP} port=5432 dbname=${GCP_POSTGRESQL_DBNAME} user=${GCP_POSTGRESQL_USERNAME} sslmode=verify-ca sslrootcert=/certs/server-ca.pem sslcert=/certs/client-cert.pem sslkey=/tmp/client-key.pem" \
        -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
    volumeMounts:
    - name: certs
      mountPath: /certs
      readOnly: true
  volumes:
  - name: certs
    secret:
      secretName: quay-db-client-certs
EOF

oc apply -f "${extension_pod_dir}/db-extension-pod.yaml"
if ! oc -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/quay-db-extension --timeout=5m; then
  echo "ERROR: the pg_trgm extension pod did not succeed; pod logs:" >&2
  oc -n default logs quay-db-extension >&2 || true
  cleanup_extension_pod
  exit 1
fi
oc -n default logs quay-db-extension
cleanup_extension_pod

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
DB_URI: postgresql://${DB_URI_USER}:${DB_URI_PASS}@${QUAY_DB_PRIVATE_IP}:5432/${GCP_POSTGRESQL_DBNAME}?sslmode=verify-ca&sslcert=/.postgresql/postgresql.crt&sslkey=/.postgresql/postgresql.key&sslrootcert=/.postgresql/root.crt
EOF

echo "Google Cloud SQL provisioning completed successfully"
echo "Database details, certificates, and config fragment saved to SHARED_DIR"
