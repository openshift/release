#!/bin/bash
set -o nounset
set -o pipefail
# NOTE: set -e is intentionally omitted — cleanup must never fail the job.

echo "--- Deprovisioning ipecho bastion ---"

# Check if there is anything to clean up
if [[ ! -f "${SHARED_DIR}/ipecho_instance_id" ]]; then
  echo "No ipecho_instance_id found in SHARED_DIR, nothing to clean up."
  exit 0
fi

INSTANCE_ID=$(cat "${SHARED_DIR}/ipecho_instance_id")
REGION=$(cat "${SHARED_DIR}/ipecho_region" 2>/dev/null || echo "us-east-1")
SG_ID=""
if [[ -f "${SHARED_DIR}/ipecho_security_group_id" ]]; then
  SG_ID=$(cat "${SHARED_DIR}/ipecho_security_group_id")
fi

export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-pool-aws-credentials/.awscred"
export AWS_DEFAULT_REGION="${REGION}"

echo "Instance ID: ${INSTANCE_ID}"
echo "Security Group: ${SG_ID:-<not set>}"
echo "Region: ${REGION}"

# --- 1. Terminate the instance ---
echo "Terminating instance ${INSTANCE_ID}..."
aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" || true

echo "Waiting for instance to terminate..."
aws ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" || true

echo "Instance terminated."

# --- 2. Delete security group with retry loop ---
if [[ -n "${SG_ID}" ]]; then
  echo "Deleting security group ${SG_ID}..."
  for attempt in $(seq 1 5); do
    if aws ec2 delete-security-group --group-id "${SG_ID}" 2>/dev/null; then
      echo "Security group deleted."
      break
    fi
    if [[ ${attempt} -eq 5 ]]; then
      echo "WARNING: Could not delete security group ${SG_ID} after 5 attempts. It may need manual cleanup."
      break
    fi
    echo "  Attempt ${attempt}/5: security group still in use (ENI detaching), retrying in 15s..."
    sleep 15
  done
fi

echo "--- ipecho bastion deprovisioned ---"
