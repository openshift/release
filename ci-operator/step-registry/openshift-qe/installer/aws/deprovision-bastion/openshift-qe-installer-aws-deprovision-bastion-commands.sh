#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

ensure_aws_cli() {
  if command -v aws &>/dev/null; then
    return 0
  fi
  echo "Installing AWS CLI..."
  pip install awscli 2>/dev/null || pip3 install awscli
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v aws &>/dev/null; then
    local user_bin
    user_bin="$(python3 -m site --user-base 2>/dev/null)/bin"
    export PATH="${user_bin}:${PATH}"
  fi
  if ! command -v aws &>/dev/null; then
    echo "ERROR: aws CLI not found after pip install (PATH=${PATH})" >&2
    exit 1
  fi
  echo "aws CLI: $(command -v aws)"
}

ensure_aws_cli

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

RESOURCES_FILE="${SHARED_DIR}/evpn-bastion-resources.json"

echo "=== Deprovisioning AWS bastion instance ==="

if [[ ! -f "${RESOURCES_FILE}" ]]; then
  echo "No resources file found, nothing to clean up"
  exit 0
fi

INSTANCE_ID=$(jq -r '.instance_id // empty' "${RESOURCES_FILE}" 2>/dev/null || true)
KEY_NAME=$(jq -r '.key_name // empty' "${RESOURCES_FILE}" 2>/dev/null || true)
WORKER_ENI_ID=$(jq -r '.worker_eni_id // empty' "${RESOURCES_FILE}" 2>/dev/null || true)
EIP_ALLOC=$(jq -r '.eip_allocation_id // empty' "${RESOURCES_FILE}" 2>/dev/null || true)

if [[ -n "${INSTANCE_ID}" ]]; then
  INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query "Reservations[*].Instances[*].State.Name" --output text 2>/dev/null || true)
  if [[ -n "${INSTANCE_STATE}" && "${INSTANCE_STATE}" != "terminated" ]]; then
    echo "Terminating instance ${INSTANCE_ID} (state: ${INSTANCE_STATE})"
    aws --region "${REGION}" ec2 terminate-instances --instance-ids "${INSTANCE_ID}" || true
    aws --region "${REGION}" ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" || true
    echo "Instance terminated"
  else
    echo "Instance ${INSTANCE_ID} already terminated or not found"
  fi
fi

if [[ -n "${WORKER_ENI_ID}" ]]; then
  attachment_id=$(aws --region "${REGION}" ec2 describe-network-interfaces \
    --network-interface-ids "${WORKER_ENI_ID}" \
    --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
  if [[ -n "${attachment_id}" && "${attachment_id}" != "None" ]]; then
    echo "Detaching worker ENI ${WORKER_ENI_ID}..."
    aws --region "${REGION}" ec2 detach-network-interface \
      --attachment-id "${attachment_id}" --force || true
  fi
  echo "Deleting worker ENI ${WORKER_ENI_ID}..."
  aws --region "${REGION}" ec2 delete-network-interface \
    --network-interface-id "${WORKER_ENI_ID}" || true
fi

if [[ -n "${EIP_ALLOC}" ]]; then
  echo "Releasing Elastic IP: ${EIP_ALLOC}"
  aws --region "${REGION}" ec2 release-address --allocation-id "${EIP_ALLOC}" || true
fi

if [[ -n "${KEY_NAME}" ]]; then
  echo "Deleting key pair: ${KEY_NAME}"
  aws --region "${REGION}" ec2 delete-key-pair --key-name "${KEY_NAME}" || true
fi

echo "=== Cleanup complete ==="
