#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${AWS_SECUREBOOT_ENABLED}" != "true" ]]; then
  echo "AWS_SECUREBOOT_ENABLED is not 'true', skipping Secure Boot verification"
  exit 0
fi

EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${AWS_REGION_OVERWRITE:-${LEASED_RESOURCE}}"
export AWS_DEFAULT_REGION="${REGION}"

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

ret=0

echo "$(date -u --rfc-3339=seconds) - Checking AWS instance boot mode for worker instances..."
readarray -t INSTANCE_IDS < <(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n')

for instance_id in "${INSTANCE_IDS[@]}"; do
  current_ami=$(aws ec2 describe-instances --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].ImageId' --output text)
  ami_boot_mode=$(aws ec2 describe-images --image-ids "${current_ami}" \
    --query 'Images[0].BootMode' --output text 2>/dev/null || echo "unknown")

  if [[ "${ami_boot_mode}" == "uefi" ]]; then
    echo "$(date -u --rfc-3339=seconds) - PASS: Instance ${instance_id} AMI ${current_ami} has boot mode '${ami_boot_mode}'"
  else
    echo "$(date -u --rfc-3339=seconds) - INFO: Instance ${instance_id} AMI ${current_ami} has boot mode '${ami_boot_mode}' (control plane nodes use stock AMI)"
  fi
done

echo ""
echo "$(date -u --rfc-3339=seconds) - Checking mokutil Secure Boot state on worker nodes..."
WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o name)
if [[ -z "${WORKERS}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: No worker nodes found"
  exit 1
fi

for node in ${WORKERS}; do
  echo "$(date -u --rfc-3339=seconds) - Checking ${node}..."
  SB_STATE=$(oc debug "${node}" -- chroot /host mokutil --sb-state 2>/dev/null || true)
  echo "  ${SB_STATE}"
  if echo "${SB_STATE}" | grep -q "SecureBoot enabled"; then
    echo "$(date -u --rfc-3339=seconds) - PASS: ${node} has Secure Boot enabled"
  else
    echo "$(date -u --rfc-3339=seconds) - FAIL: ${node} does NOT have Secure Boot enabled"
    ret=1
  fi
done

if [[ "${ret}" -ne 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Secure Boot verification failed on one or more workers"
fi

exit ${ret}
