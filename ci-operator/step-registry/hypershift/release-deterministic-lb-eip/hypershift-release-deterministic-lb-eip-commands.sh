#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/etc/hypershift-ci-jobs-awscreds/credentials}"

TAG_NAME="${EIP_TAG_NAME:-CNTRLPLANE-4579-e2e}"
ENV_FILE="${SHARED_DIR}/eip.env"
EIP_ALLOCATION_ID=""
EIP_ASSOCIATION=""

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

if [[ -z "${MGMT_REGION:-}" ]]; then
    MGMT_REGION=$(kubectl get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
fi
if [[ -z "${MGMT_REGION:-}" ]]; then
    echo "could not discover the management cluster AWS region" >&2
    exit 2
fi

aws_cmd() {
    aws --region "${MGMT_REGION}" "$@"
}

if [[ -z "${EIP_ALLOCATION_ID:-}" || "${EIP_ALLOCATION_ID}" == "None" ]]; then
    EIP_ALLOCATION_ID=$(aws_cmd ec2 describe-addresses \
        --filters "Name=tag:Name,Values=${TAG_NAME}" \
        --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)
fi
if [[ -z "${EIP_ALLOCATION_ID:-}" || "${EIP_ALLOCATION_ID}" == "None" ]]; then
    echo "no EIP found for tag ${TAG_NAME}; nothing to release"
    exit 0
fi

for _ in $(seq 1 60); do
    EIP_ASSOCIATION=$(aws_cmd ec2 describe-addresses --allocation-ids "${EIP_ALLOCATION_ID}" \
        --query 'Addresses[0].AssociationId' --output text 2>/dev/null || true)
    if [[ -z "${EIP_ASSOCIATION}" || "${EIP_ASSOCIATION}" == "None" ]]; then
        break
    fi
    sleep 10
done
if [[ -n "${EIP_ASSOCIATION:-}" && "${EIP_ASSOCIATION}" != "None" ]]; then
    echo "refusing to release ${EIP_ALLOCATION_ID}: still associated to ${EIP_ASSOCIATION}" >&2
    exit 1
fi

aws_cmd ec2 release-address --allocation-id "${EIP_ALLOCATION_ID}"
echo "released EIP ${EIP_ALLOCATION_ID}"
