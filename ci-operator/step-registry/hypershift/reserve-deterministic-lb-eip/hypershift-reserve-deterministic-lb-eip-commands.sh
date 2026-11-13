#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/etc/hypershift-ci-jobs-awscreds/credentials}"

for required_command in aws oc; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "${required_command} is required in the resolved step image" >&2
        exit 1
    fi
done

TAG_NAME="${EIP_TAG_NAME:-CNTRLPLANE-4579-e2e}"
ENV_FILE="${SHARED_DIR}/eip.env"
RUN_ID_FILE="${SHARED_DIR}/eip-run-id"
LIB_FILE="${SHARED_DIR}/deterministic-lb-eip-lib.sh"
EIP_ALLOCATION_ID=""
EIP_PUBLIC_IP=""
EIP_ASSOCIATION=""

if [[ ! -f "${LIB_FILE}" ]]; then
    echo "missing shared EIP helpers at ${LIB_FILE}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${LIB_FILE}"

# Establish the run identity before allocation so cleanup can recover an
# allocation made by a failed attempt in this same execution. Prow creates a
# fresh SHARED_DIR and job ID for every new execution, so this value is not
# shared with other runs.
run_id() {
    if [[ -f "${RUN_ID_FILE}" ]]; then
        cat "${RUN_ID_FILE}"
        return
    fi

    local id
    id="${PROW_JOB_ID:-${BUILD_ID:-}}"
    if [[ -z "${id}" ]]; then
        id="$(date +%s)-$$"
    fi

    umask 077
    printf '%s\n' "${id}" > "${RUN_ID_FILE}"
    printf '%s\n' "${id}"
}
RUN_ID="$(run_id)"
if [[ -z "${RUN_ID}" ]]; then
    echo "could not determine a unique EIP run identity" >&2
    exit 2
fi

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

if [[ -z "${MGMT_REGION:-}" ]]; then
    MGMT_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
fi
if [[ -z "${MGMT_REGION:-}" ]]; then
    echo "could not discover the management cluster AWS region" >&2
    exit 2
fi

if [[ -z "${MGMT_PUBLIC_SUBNET:-}" ]]; then
    INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
    VPC_ID=$(aws_cmd ec2 describe-vpcs \
        --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
        --query 'Vpcs[0].VpcId' --output text)
    # This subnet belongs to the management VPC. The guest cluster only uses
    # the resulting annotation on the management-side KAS Service.
    MGMT_PUBLIC_SUBNET=$(aws_cmd ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=kubernetes.io/role/elb" \
        --query 'Subnets[0].SubnetId' --output text)
    if [[ -z "${MGMT_PUBLIC_SUBNET}" || "${MGMT_PUBLIC_SUBNET}" == "None" ]]; then
        MGMT_PUBLIC_SUBNET=$(aws_cmd ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[0].SubnetId' --output text)
    fi
fi
if [[ -z "${MGMT_PUBLIC_SUBNET:-}" || "${MGMT_PUBLIC_SUBNET}" == "None" ]]; then
    echo "could not discover a management cluster public subnet" >&2
    exit 2
fi

if [[ -n "${EIP_ALLOCATION_ID:-}" && "${EIP_ALLOCATION_ID}" != "None" ]]; then
    rc=0
    verify_run_eip "${EIP_ALLOCATION_ID}" || rc=$?
    if [[ $rc -eq 2 ]]; then
        EIP_ALLOCATION_ID=""
    elif [[ $rc -ne 0 ]]; then
        exit 1
    fi
fi

if [[ -z "${EIP_ALLOCATION_ID}" ]]; then
    if ! EIP_ALLOCATION_ID=$(find_run_eip); then
        exit 1
    fi
    if [[ -z "${EIP_ALLOCATION_ID}" ]]; then
        if ! ALLOCATION=$(aws_cmd ec2 allocate-address --domain vpc \
            --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${TAG_NAME}-${RUN_ID}},{Key=Jira,Value=CNTRLPLANE-4579},{Key=Purpose,Value=deterministic-lb-e2e},{Key=${EIP_RUN_TAG},Value=${RUN_ID}}]" \
            --query '[AllocationId,PublicIp]' --output text); then
            echo "failed to allocate an EIP for run ${RUN_ID}" >&2
            exit 1
        fi
        read -r EIP_ALLOCATION_ID EIP_PUBLIC_IP <<< "${ALLOCATION}"
        echo "allocated EIP ${EIP_ALLOCATION_ID} (${EIP_PUBLIC_IP}) for run ${RUN_ID}"
    else
        if ! EIP_PUBLIC_IP=$(aws_cmd ec2 describe-addresses --allocation-ids "${EIP_ALLOCATION_ID}" \
            --query 'Addresses[0].PublicIp' --output text); then
            echo "failed to describe EIP ${EIP_ALLOCATION_ID}" >&2
            exit 1
        fi
        echo "reusing EIP ${EIP_ALLOCATION_ID} (${EIP_PUBLIC_IP}) for run ${RUN_ID}"
    fi
fi

if [[ -z "${EIP_PUBLIC_IP:-}" || "${EIP_PUBLIC_IP}" == "None" ]]; then
    if ! EIP_PUBLIC_IP=$(aws_cmd ec2 describe-addresses --allocation-ids "${EIP_ALLOCATION_ID}" \
        --query 'Addresses[0].PublicIp' --output text); then
        echo "failed to describe EIP ${EIP_ALLOCATION_ID}" >&2
        exit 1
    fi
fi

if ! EIP_ASSOCIATION=$(aws_cmd ec2 describe-addresses --allocation-ids "${EIP_ALLOCATION_ID}" \
    --query 'Addresses[0].AssociationId' --output text); then
    echo "failed to describe EIP ${EIP_ALLOCATION_ID}" >&2
    exit 1
fi
if [[ -n "${EIP_ASSOCIATION}" && "${EIP_ASSOCIATION}" != "None" ]]; then
    echo "EIP ${EIP_ALLOCATION_ID} is still associated to ${EIP_ASSOCIATION}; refusing to reuse it" >&2
    exit 1
fi

umask 077
cat > "${ENV_FILE}" <<EOF
export EIP_ALLOCATION_ID=${EIP_ALLOCATION_ID}
export EIP_PUBLIC_IP=${EIP_PUBLIC_IP}
export MGMT_REGION=${MGMT_REGION}
export MGMT_PUBLIC_SUBNET=${MGMT_PUBLIC_SUBNET}
export HYPERSHIFT_E2E_RUN_ID=${RUN_ID}
export HYPERSHIFT_DETERMINISTIC_LB_EIP=${EIP_ALLOCATION_ID}
export HYPERSHIFT_DETERMINISTIC_LB_SUBNET=${MGMT_PUBLIC_SUBNET}
export HYPERSHIFT_AWS_REGION=${MGMT_REGION}
export E2E_EXPECTED_DETERMINISTIC_LB_IP=${EIP_PUBLIC_IP}
EOF
chmod 600 "${ENV_FILE}"
echo "wrote ${ENV_FILE}"
