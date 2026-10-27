#!/usr/bin/env bash

# Validate that AWS EC2 compute nodes have nested virtualization enabled.
#
# This script performs several validation checks:
# 1. AWS CpuOptions: Query EC2 API to verify NestedVirtualization is enabled
# 2. CPU flags: Check /proc/cpuinfo for vmx (Intel) or svm (AMD) flags
# 3. KVM module: Verify KVM kernel module is loaded and /dev/kvm exists

set -eu
set -o nounset
set -o errexit
set -o pipefail

# AWS credentials from cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Proxy support for private clusters
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Detect region from the deployed cluster
AWS_DEFAULT_REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
export AWS_DEFAULT_REGION

echo "============================================"
echo "Nested Virtualization Validation on AWS"
echo "Region: ${AWS_DEFAULT_REGION}"
echo "============================================"

VALIDATION_FAILURES=0

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------

fail_check() {
  echo "[FAIL] $1" >&2
  VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
}

pass_check() {
  echo "[PASS] $1"
}

# ----------------------------------------------------------------
# Check 1: AWS CpuOptions.NestedVirtualization
# ----------------------------------------------------------------

validate_aws_cpu_options() {
  local instance_id="$1"
  local node_name="$2"

  echo ""
  echo "---------------------------------------------"
  echo "Check 1: AWS EC2 CpuOptions (${node_name})"
  echo "---------------------------------------------"

  local nested_virt_status
  nested_virt_status=$(aws ec2 describe-instances \
    --region "${AWS_DEFAULT_REGION}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].CpuOptions.NestedVirtualization' \
    --output text 2>/dev/null || echo "None")

  if [[ "${nested_virt_status}" == "enabled" ]]; then
    pass_check "AWS CpuOptions.NestedVirtualization is enabled on ${node_name} (${instance_id})"
  else
    fail_check "AWS CpuOptions.NestedVirtualization is NOT enabled on ${node_name} (${instance_id}): ${nested_virt_status}"
  fi
}

# ----------------------------------------------------------------
# Check 2: CPU virtualization flags (vmx/svm)
# ----------------------------------------------------------------

validate_cpu_flags() {
  local node_name="$1"

  echo ""
  echo "---------------------------------------------"
  echo "Check 2: CPU Virtualization Flags (${node_name})"
  echo "---------------------------------------------"

  # Capture full cpuinfo output first to avoid broken pipe with grep -m1
  local cpuinfo
  cpuinfo=$(oc debug "node/${node_name}" -- chroot /host cat /proc/cpuinfo 2>/dev/null)
  local cpu_flags
  cpu_flags=$(awk -F: '/^flags/ { print $2; exit }' <<< "${cpuinfo}")

  if echo "${cpu_flags}" | grep -qw 'vmx'; then
    pass_check "Intel VT-x (vmx) flag found on ${node_name}"
  elif echo "${cpu_flags}" | grep -qw 'svm'; then
    pass_check "AMD-V (svm) flag found on ${node_name}"
  else
    fail_check "No virtualization flags (vmx or svm) found on ${node_name}"
  fi
}

# ----------------------------------------------------------------
# Check 3: KVM kernel module and /dev/kvm
# ----------------------------------------------------------------

validate_kvm_module() {
  local node_name="$1"

  echo ""
  echo "---------------------------------------------"
  echo "Check 3: KVM Module & Device (${node_name})"
  echo "---------------------------------------------"

  # Check if KVM module is loaded
  local kvm_loaded
  kvm_loaded=$(oc debug "node/${node_name}" -- chroot /host lsmod 2>/dev/null | grep -c '^kvm' || echo "0")

  if [[ "${kvm_loaded}" -gt 0 ]]; then
    pass_check "KVM kernel module is loaded on ${node_name}"
  else
    fail_check "KVM kernel module is NOT loaded on ${node_name}"
  fi

  # Check if /dev/kvm exists
  if oc debug "node/${node_name}" -- chroot /host test -e /dev/kvm 2>/dev/null; then
    pass_check "/dev/kvm device exists on ${node_name}"
  else
    fail_check "/dev/kvm device does NOT exist on ${node_name}"
  fi
}

# ----------------------------------------------------------------
# Main validation loop
# ----------------------------------------------------------------

main() {
  local workers_count="${COMPUTE_NODE_REPLICAS:-3}"
  local machine_selector

  if [[ "${workers_count}" -eq 0 ]]; then
    machine_selector='machine.openshift.io/cluster-api-machine-role=master'
    echo "Compact/SNO cluster (COMPUTE_NODE_REPLICAS=0): validating control-plane nodes."
  else
    machine_selector='machine.openshift.io/cluster-api-machine-role=worker'
    echo "Standard cluster: validating worker nodes."
  fi

  local machines
  machines=$(oc get machines -n openshift-machine-api \
    -l "${machine_selector}" \
    -o json)

  local count
  count=$(echo "${machines}" | jq '.items | length')

  if [[ "${count}" -eq 0 ]]; then
    echo "[ERROR] No machines found with selector ${machine_selector}." >&2
    exit 1
  fi

  echo "Found ${count} machine(s) to validate."
  echo ""

  local i
  for ((i = 0; i < count; i++)); do
    local instance_id node_name
    instance_id=$(echo "${machines}" | jq -r ".items[${i}].status.providerStatus.instanceId")
    node_name=$(echo "${machines}" | jq -r ".items[${i}].status.nodeRef.name")

    if [[ -z "${instance_id}" || "${instance_id}" == "null" ]]; then
      echo "[WARN] Machine index ${i} has no instance ID, skipping."
      VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
      continue
    fi

    echo "========================================"
    echo "Validating Node: ${node_name}"
    echo "Instance ID: ${instance_id}"
    echo "========================================"

    # Run all validation checks
    validate_aws_cpu_options "${instance_id}" "${node_name}"
    validate_cpu_flags "${node_name}"
    validate_kvm_module "${node_name}"
  done

  echo ""
  echo "============================================"
  echo "Validation Summary"
  echo "============================================"
  echo "Total validation failures: ${VALIDATION_FAILURES}"

  if [[ "${VALIDATION_FAILURES}" -gt 0 ]]; then
    echo "[FAIL] Nested virtualization validation failed."
    exit 1
  else
    echo "[PASS] All nested virtualization checks passed!"
    exit 0
  fi
}

main "$@"
