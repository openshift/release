#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-byo-vpc.yaml.patch

NETWORK="do-not-delete-shared-network"
MASTER_SUBNET="do-not-delete-shared-master-subnet"
WORKER_SUBNET="do-not-delete-shared-worker-subnet"

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GOOGLE_PROJECT_ID="$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")"
sa_email=$(jq -r '.client_email' "${GCP_SHARED_CREDENTIALS_FILE}")
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

REGION="${LEASED_RESOURCE}"

if ! gcloud compute networks describe "${NETWORK}" --project="${GOOGLE_PROJECT_ID}" &>/dev/null; then
  echo "$(date -u --rfc-3339=seconds) - Network '${NETWORK}' not found, creating..."
  gcloud compute networks create "${NETWORK}" \
    --project="${GOOGLE_PROJECT_ID}" \
    --subnet-mode=custom
fi

REGIONS=("us-central1" "us-east1" "us-east4")

REGION_FOUND=false
for r in "${REGIONS[@]}"; do
  if [[ "${r}" == "${REGION}" ]]; then
    REGION_FOUND=true
    break
  fi
done
if [[ "${REGION_FOUND}" == "false" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Region '${REGION}' not in predefined list, adding..."
  REGIONS+=("${REGION}")
fi

next_cidr_block() {
  local existing
  existing=$(gcloud compute networks subnets list \
    --network="${NETWORK}" \
    --project="${GOOGLE_PROJECT_ID}" \
    --format="value(ipCidrRange)" 2>/dev/null)

  for third_octet in $(seq 0 32 224); do
    local candidate="10.0.${third_octet}.0/19"
    if ! echo "${existing}" | grep -qF "${candidate}"; then
      echo "${candidate}"
      return
    fi
  done

  echo "$(date -u --rfc-3339=seconds) - ERROR: No more /19 blocks available in 10.0.0.0/16" >&2
  exit 1
}

for r in "${REGIONS[@]}"; do
  if ! gcloud compute networks subnets describe "${MASTER_SUBNET}" --region="${r}" --project="${GOOGLE_PROJECT_ID}" &>/dev/null; then
    CIDR=$(next_cidr_block)
    echo "$(date -u --rfc-3339=seconds) - Subnet '${MASTER_SUBNET}' not found in ${r}, creating with ${CIDR}..."
    gcloud compute networks subnets create "${MASTER_SUBNET}" \
      --network="${NETWORK}" \
      --region="${r}" \
      --range="${CIDR}" \
      --project="${GOOGLE_PROJECT_ID}"
  fi

  if ! gcloud compute networks subnets describe "${WORKER_SUBNET}" --region="${r}" --project="${GOOGLE_PROJECT_ID}" &>/dev/null; then
    CIDR=$(next_cidr_block)
    echo "$(date -u --rfc-3339=seconds) - Subnet '${WORKER_SUBNET}' not found in ${r}, creating with ${CIDR}..."
    gcloud compute networks subnets create "${WORKER_SUBNET}" \
      --network="${NETWORK}" \
      --region="${r}" \
      --range="${CIDR}" \
      --project="${GOOGLE_PROJECT_ID}"
  fi
done

ROUTER="do-not-delete-shared-router"
NAT="do-not-delete-shared-nat"

for r in "${REGIONS[@]}"; do
  if ! gcloud compute routers describe "${ROUTER}" --region="${r}" --project="${GOOGLE_PROJECT_ID}" &>/dev/null; then
    echo "$(date -u --rfc-3339=seconds) - Router '${ROUTER}' not found in ${r}, creating..."
    gcloud compute routers create "${ROUTER}" \
      --network="${NETWORK}" \
      --region="${r}" \
      --project="${GOOGLE_PROJECT_ID}"
  fi

  if ! gcloud compute routers nats describe "${NAT}" --router="${ROUTER}" --region="${r}" --project="${GOOGLE_PROJECT_ID}" &>/dev/null; then
    echo "$(date -u --rfc-3339=seconds) - Cloud NAT '${NAT}' not found in ${r}, creating..."
    gcloud compute routers nats create "${NAT}" \
      --router="${ROUTER}" \
      --region="${r}" \
      --auto-allocate-nat-external-ips \
      --nat-all-subnet-ip-ranges \
      --project="${GOOGLE_PROJECT_ID}"
  fi
done

ensure_firewall_rule() {
  local name="$1" network="$2" project="$3"
  shift 3
  if ! gcloud compute firewall-rules describe "${name}" --project="${project}" &>/dev/null; then
    echo "$(date -u --rfc-3339=seconds) - Firewall rule '${name}' not found, creating..."
    gcloud compute firewall-rules create "${name}" \
      --network="${network}" \
      --project="${project}" \
      "$@"
  fi
}

# control-plane: worker<->master communication
ensure_firewall_rule "do-not-delete-shared-control-plane" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:22623,tcp:10257,tcp:10259" \
  --source-ranges="10.0.0.0/16"

# etcd: master<->master
ensure_firewall_rule "do-not-delete-shared-etcd" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:2379-2380" \
  --source-ranges="10.0.0.0/16"

# health-checks: GCP health check ranges to masters
ensure_firewall_rule "do-not-delete-shared-health-checks" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:6080,tcp:6443,tcp:22624" \
  --source-ranges="35.191.0.0/16,130.211.0.0/22,209.85.152.0/22,209.85.204.0/22"

# internal-cluster: k8s NodePorts, host services, overlay, kubelet
ensure_firewall_rule "do-not-delete-shared-internal-cluster" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:30000-32767,udp:30000-32767,tcp:9000-9999,udp:9000-9999,udp:4789,udp:6081,udp:500,udp:4500,tcp:10250,esp" \
  --source-ranges="10.0.0.0/16"

# api: kube-apiserver access (external)
ensure_firewall_rule "do-not-delete-shared-api" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:6443"

# internal-network: SSH and ICMP within machine CIDR
ensure_firewall_rule "do-not-delete-shared-internal-network" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:22,icmp" \
  --source-ranges="10.0.0.0/16"

# bootstrap-ssh: SSH access for bootstrap (external)
ensure_firewall_rule "do-not-delete-shared-bootstrap-ssh" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:22,icmp" \
  --source-ranges="0.0.0.0/0"

# bootstrap-konnectivity: konnectivity during bootstrap
ensure_firewall_rule "do-not-delete-shared-konnectivity" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:8091" \
  --source-ranges="10.0.0.0/16"

# CAPG default rules - these are normally created by cluster-api-provider-gcp during
# GCPCluster reconciliation and removed by the installer after InfraReady.
# In BYO VPC they must pre-exist. We use source-ranges instead of source/target tags
# since the infraID is not known at this point.

# capg-healthchecks: GCP health check probes to kube-apiserver (CAPG uses only 35.191.0.0/16 and 130.211.0.0/22)
ensure_firewall_rule "do-not-delete-shared-capg-healthchecks" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="tcp:6443" \
  --source-ranges="35.191.0.0/16,130.211.0.0/22"

# capg-cluster: all traffic between cluster nodes (CAPG uses source/target tags; we use subnet ranges)
ensure_firewall_rule "do-not-delete-shared-capg-cluster" "${NETWORK}" "${GOOGLE_PROJECT_ID}" \
  --allow="all" \
  --source-ranges="10.0.0.0/16"

cat > "${PATCH}" << EOF
platform:
  gcp:
    network: ${NETWORK}
    controlPlaneSubnet: ${MASTER_SUBNET}
    computeSubnet: ${WORKER_SUBNET}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
