#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

python3 --version 
export CLOUDSDK_PYTHON=python3

CLUSTER_NETWORK=""
if [[ -s "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  CLUSTER_NETWORK=$(yq-go r "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.gcp.network')
fi

if [[ -z "${CLUSTER_NETWORK}" ]]; then
  echo "Could not find VPC network." && exit 1
fi

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function create_firewall_rules()
{
  local -r infra_id="$1"; shift
  local -r cluster_network="$1"; shift
  local -r network_cidr="$1"; shift
  local -r allowed_external_cidr="$1"; shift
  local -r control_plane_nodes_tags="$1"; shift
  local -r compute_nodes_tags="$1"; shift
  local -r create_ingress_k8s_fw="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD

  CMD="gcloud compute firewall-rules create ${infra_id}-bootstrap-in-ssh --network=${cluster_network} --allow=tcp:22 --source-ranges=${allowed_external_cidr} --target-tags=${control_plane_nodes_tags}"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-api --network=${cluster_network} --allow=tcp:6443 --source-ranges=${allowed_external_cidr} --target-tags=${control_plane_nodes_tags}"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-health-checks --network=${cluster_network} --allow=tcp:6080,tcp:6443,tcp:22624 --source-ranges=35.191.0.0/16,130.211.0.0/22,209.85.152.0/22,209.85.204.0/22 --target-tags=${control_plane_nodes_tags}"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-etcd --network=${cluster_network} --allow=tcp:2379-2380 --source-tags=${control_plane_nodes_tags} --target-tags=${control_plane_nodes_tags}"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-control-plane --network=${cluster_network} --allow=tcp:10257,tcp:10259,tcp:22623 --source-tags=${control_plane_nodes_tags},${compute_nodes_tags} --target-tags=${control_plane_nodes_tags}"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-internal-network --network=${cluster_network} --allow=icmp,tcp:22 --source-ranges=${network_cidr} --target-tags=${control_plane_nodes_tags},${compute_nodes_tags}"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-internal-cluster --network=${cluster_network} --allow=udp:4789,udp:6081,udp:500,udp:4500,esp,tcp:9000-9999,udp:9000-9999,tcp:10250,tcp:30000-32767,udp:30000-32767 --source-tags=${control_plane_nodes_tags},${compute_nodes_tags} --target-tags=${control_plane_nodes_tags},${compute_nodes_tags}"
  run_command "${CMD}"

  if "${create_ingress_k8s_fw}"; then
    CMD="gcloud compute firewall-rules create ${infra_id}-ingress-k8s-fw --network=${cluster_network} --allow=tcp:80,tcp:443 --source-ranges=${allowed_external_cidr} --target-tags=${control_plane_nodes_tags},${compute_nodes_tags}"
    run_command "${CMD}"

    CMD="gcloud compute firewall-rules create ${infra_id}-ingress-k8s-http-hc --network=${cluster_network} --allow=tcp:30000-32767 --source-ranges=35.191.0.0/16,130.211.0.0/22,209.85.152.0/22,209.85.204.0/22 --target-tags=${control_plane_nodes_tags},${compute_nodes_tags}"
    run_command "${CMD}"
  fi

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud compute firewall-rules delete -q ${infra_id}-bootstrap-in-ssh ${infra_id}-api ${infra_id}-health-checks ${infra_id}-etcd ${infra_id}-control-plane ${infra_id}-internal-network ${infra_id}-internal-cluster
EOF
  if "${create_ingress_k8s_fw}"; then
    cat >> "${deprovision_commands_file}" << EOF
gcloud compute firewall-rules delete -q ${infra_id}-ingress-k8s-fw ${infra_id}-ingress-k8s-http-hc
EOF
  fi
}

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

echo "$(date -u --rfc-3339=seconds) - Creating the firewall-rules within the VPC network..."
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
FIREWALL_RULES_DEPROVISION_SCRIPTS="${SHARED_DIR}/03_firewall_rules_deprovision.sh"

create_firewall_rules "${CLUSTER_NAME}" "${CLUSTER_NETWORK}" "${NETWORK_CIDR}" "0.0.0.0/0" "${NETWORK_TAGS_FOR_CONTROL_PLANE_NODES}" "${NETWORK_TAGS_FOR_COMPUTE_NODES}" true "${FIREWALL_RULES_DEPROVISION_SCRIPTS}"

echo "$(date -u --rfc-3339=seconds) - The pre-created firewall-rules within the VPC network"
CMD="gcloud compute firewall-rules list --filter='network=${CLUSTER_NETWORK}'"
run_command "${CMD}"