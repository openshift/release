#!/bin/bash

#
# Enable nested virtualization on AWS EC2 instances after OCP cluster deployment.
#
# AWS EC2 non-metal instances (c8i, m8i, r8i families) support nested virtualization
# but it must be explicitly enabled via CpuOptions. The OpenShift Machine API does not
# yet support this field, so this script enables it post-deploy using the AWS CLI.
#
# Bare-metal instances (*.metal) have native KVM access and are skipped.
#
# For compact/SNO clusters (COMPUTE_NODE_REPLICAS=0), master nodes are also processed
# since they schedule VM workloads.
#
# Instance type is read from env vars (COMPUTE_NODE_TYPE / CONTROL_PLANE_INSTANCE_TYPE),
# falling back to auto-detection from Machine API objects.
#
# Requires: AWS CLI v2, oc, jq
#

set -o nounset
set -o errexit
set -o pipefail

# AWS credentials from cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Proxy support for private clusters (must be before any oc calls)
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Detect region from the deployed cluster
AWS_DEFAULT_REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
export AWS_DEFAULT_REGION

# Instance type families that support nested virtualization (Intel 8th gen on Nitro).
readonly NESTED_VIRT_FAMILIES="c8i m8i r8i"

# ────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────

is_metal_instance() {
  [[ "$1" == *.metal* ]]
}

# Extract the family prefix from an instance type (e.g., "m8i" from "m8i.8xlarge").
instance_family() {
  echo "${1%%.*}"
}

supports_nested_virt() {
  local family
  family=$(instance_family "$1")
  [[ " ${NESTED_VIRT_FAMILIES} " == *" ${family} "* ]]
}

require_aws_cli_v2() {
  if ! command -v aws &>/dev/null; then
    echo "[ERROR] AWS CLI not found in PATH." >&2
    exit 1
  fi

  local version
  version=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9]+' | head -1)
  local major="${version##*/}"

  if [[ "${major}" -lt 2 ]]; then
    echo "[ERROR] AWS CLI v2 is required (found: $(aws --version 2>&1))." >&2
    echo "[ERROR] The 'modify-instance-cpu-options --nested-virtualization' flag is only available in AWS CLI v2." >&2
    exit 1
  fi
}

# ────────────────────────────────────────────────────────────────
# Core: enable nested virt on a single EC2 instance / OCP node
# ────────────────────────────────────────────────────────────────

enable_nested_virt_on_node() {
  local instance_id="$1"
  local node_name="$2"
  local region="${AWS_DEFAULT_REGION}"

  echo "[INFO] Processing node ${node_name} (${instance_id})"

  # Get current CPU options to preserve core-count and threads-per-core.
  local cpu_opts
  cpu_opts=$(aws ec2 describe-instances \
    --region "${region}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].CpuOptions' \
    --output json)

  local core_count threads_per_core
  core_count=$(echo "${cpu_opts}" | jq -r '.CoreCount')
  threads_per_core=$(echo "${cpu_opts}" | jq -r '.ThreadsPerCore')

  # Check if nested virt is already enabled.
  local nested_virt_status
  nested_virt_status=$(aws ec2 describe-instances \
    --region "${region}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].CpuOptions.NestedVirtualization' \
    --output text 2>/dev/null || echo "None")

  if [[ "${nested_virt_status}" == "enabled" ]]; then
    echo "[INFO] Nested virtualization already enabled on ${node_name}, skipping."
    return 0
  fi

  # 1. Cordon
  echo "[INFO] Cordoning ${node_name}"
  oc adm cordon "${node_name}"

  # 2. Drain
  echo "[INFO] Draining ${node_name}"
  oc adm drain "${node_name}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=300s || true

  # 3. Stop EC2 instance
  echo "[INFO] Stopping EC2 instance ${instance_id}"
  aws ec2 stop-instances --region "${region}" --instance-ids "${instance_id}" >/dev/null
  aws ec2 wait instance-stopped --region "${region}" --instance-ids "${instance_id}"
  echo "[INFO] Instance ${instance_id} stopped."

  # 4. Enable nested virtualization
  echo "[INFO] Enabling nested virtualization on ${instance_id}"
  aws ec2 modify-instance-cpu-options \
    --region "${region}" \
    --instance-id "${instance_id}" \
    --core-count "${core_count}" \
    --threads-per-core "${threads_per_core}" \
    --nested-virtualization enabled >/dev/null

  # 5. Start EC2 instance (with retry for InsufficientInstanceCapacity)
  echo "[INFO] Starting EC2 instance ${instance_id}"
  local attempt
  for attempt in $(seq 1 10); do
    if aws ec2 start-instances --region "${region}" --instance-ids "${instance_id}" >/dev/null 2>&1; then
      break
    fi
    echo "[WARN] Start attempt ${attempt}/10 failed (capacity). Retrying in 30s..."
    sleep 30
  done

  aws ec2 wait instance-running --region "${region}" --instance-ids "${instance_id}"
  echo "[INFO] Instance ${instance_id} running."

  # 6. Wait for node to be Ready in OCP
  echo "[INFO] Waiting for node ${node_name} to become Ready"
  oc wait --for=condition=Ready "node/${node_name}" --timeout=600s

  # 7. Uncordon
  echo "[INFO] Uncordoning ${node_name}"
  oc adm uncordon "${node_name}"

  echo "[INFO] Nested virtualization enabled on ${node_name}."
}

# ────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────

main() {
  local flavor="${COMPUTE_NODE_TYPE:-}"
  local workers_count="${COMPUTE_NODE_REPLICAS:-3}"
  local machine_selector

  if [[ "${workers_count}" -eq 0 ]]; then
    machine_selector='machine.openshift.io/cluster-api-machine-role=master'
    flavor="${CONTROL_PLANE_INSTANCE_TYPE:-${flavor}}"
    echo "[INFO] Compact/SNO cluster (COMPUTE_NODE_REPLICAS=0): checking control-plane instance type."
  else
    machine_selector='machine.openshift.io/cluster-api-machine-role=worker'
  fi

  # Fallback: detect instance type from Machine API if not set via env
  if [[ -z "${flavor}" ]]; then
    echo "[INFO] No instance type env var set, detecting from Machine API..."
    flavor=$(oc get machines -n openshift-machine-api \
      -l "${machine_selector}" \
      -o jsonpath='{.items[0].spec.providerSpec.value.instanceType}')
  fi

  if [[ -z "${flavor}" ]]; then
    echo "[ERROR] Could not determine instance type from env or Machine API." >&2
    exit 1
  fi

  echo "[INFO] Instance type: ${flavor}"

  # Skip bare-metal instances — they have native KVM.
  if is_metal_instance "${flavor}"; then
    echo "[INFO] Bare-metal instance (${flavor}): nested virtualization not needed. Skipping."
    return 0
  fi

  # Skip unsupported instance families.
  if ! supports_nested_virt "${flavor}"; then
    echo "[WARN] Instance family '$(instance_family "${flavor}")' does not support nested virtualization."
    echo "[WARN] Supported families: ${NESTED_VIRT_FAMILIES}"
    echo "[WARN] KVM will not be available. VMs will fail to schedule."
    return 0
  fi

  require_aws_cli_v2

  echo "[INFO] Enabling nested virtualization on ${machine_selector} machines..."

  local machines
  machines=$(oc get machines -n openshift-machine-api \
    -l "${machine_selector}" \
    -o json)

  local count
  count=$(echo "${machines}" | jq '.items | length')

  if [[ "${count}" -eq 0 ]]; then
    echo "[WARN] No machines found with selector ${machine_selector}."
    return 0
  fi

  echo "[INFO] Found ${count} machine(s) to process."

  local i
  for ((i = 0; i < count; i++)); do
    local instance_id node_name
    instance_id=$(echo "${machines}" | jq -r ".items[${i}].status.providerStatus.instanceId")
    node_name=$(echo "${machines}" | jq -r ".items[${i}].status.nodeRef.name")

    if [[ -z "${instance_id}" || "${instance_id}" == "null" ]]; then
      echo "[WARN] Machine index ${i} has no instance ID, skipping."
      continue
    fi

    enable_nested_virt_on_node "${instance_id}" "${node_name}"
  done

  echo "[INFO] Nested virtualization setup complete."
}

main "$@"
