#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/etc/hypershift-ci-jobs-awscreds/credentials}"

TAG_NAME="${EIP_TAG_NAME:-CNTRLPLANE-4579-e2e}"
ENV_FILE="${SHARED_DIR}/eip.env"
EIP_ALLOCATION_ID=""
EIP_PUBLIC_IP=""
EIP_ASSOCIATION=""

aws_cmd() {
    aws --region "${MGMT_REGION}" "$@"
}

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

if [[ -z "${MGMT_PUBLIC_SUBNET:-}" ]]; then
    INFRA_ID=$(kubectl get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
    VPC_ID=$(aws_cmd ec2 describe-vpcs \
        --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
        --query 'Vpcs[0].VpcId' --output text)
    MGMT_PUBLIC_SUBNET=$(aws_cmd ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=kubernetes.io/role/elb" \
        --query 'Subnets[0].SubnetId' --output text)
    if [[ -z "${MGMT_PUBLIC_SUBNET}" || "${MGMT_PUBLIC_SUBNET}" == "None" ]]; then
        MGMT_PUBLIC_SUBNET=$(aws_cmd ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[0].SubnetId' --output text)
    fi
fi

EXISTING=$(aws_cmd ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${TAG_NAME}" \
    --query 'Addresses[0].[AllocationId,PublicIp,AssociationId]' --output text 2>/dev/null || true)
read -r EIP_ALLOCATION_ID EIP_PUBLIC_IP EIP_ASSOCIATION <<< "${EXISTING}" || true

if [[ -z "${EIP_ALLOCATION_ID:-}" || "${EIP_ALLOCATION_ID}" == "None" ]]; then
    ALLOCATION=$(aws_cmd ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${TAG_NAME}},{Key=Jira,Value=CNTRLPLANE-4579},{Key=Purpose,Value=deterministic-lb-e2e}]" \
        --query '[AllocationId,PublicIp]' --output text)
    read -r EIP_ALLOCATION_ID EIP_PUBLIC_IP <<< "${ALLOCATION}"
    echo "allocated EIP ${EIP_ALLOCATION_ID} (${EIP_PUBLIC_IP})"
else
    echo "reusing EIP ${EIP_ALLOCATION_ID} (${EIP_PUBLIC_IP})"
fi

if [[ -n "${EIP_ASSOCIATION:-}" && "${EIP_ASSOCIATION}" != "None" ]]; then
    echo "warning: EIP is associated to ${EIP_ASSOCIATION}; the old HC/NLB must be gone before creating a new HC" >&2
fi

umask 077
cat > "${ENV_FILE}" <<EOF
export EIP_ALLOCATION_ID=${EIP_ALLOCATION_ID}
export EIP_PUBLIC_IP=${EIP_PUBLIC_IP}
export MGMT_REGION=${MGMT_REGION}
export MGMT_PUBLIC_SUBNET=${MGMT_PUBLIC_SUBNET}
export HYPERSHIFT_DETERMINISTIC_LB_EIP=${EIP_ALLOCATION_ID}
export HYPERSHIFT_DETERMINISTIC_LB_SUBNET=${MGMT_PUBLIC_SUBNET}
export HYPERSHIFT_AWS_REGION=${MGMT_REGION}
export E2E_EXPECTED_DETERMINISTIC_LB_IP=${EIP_PUBLIC_IP}
EOF
chmod 600 "${ENV_FILE}"
echo "wrote ${ENV_FILE}"
cat "${ENV_FILE}"
