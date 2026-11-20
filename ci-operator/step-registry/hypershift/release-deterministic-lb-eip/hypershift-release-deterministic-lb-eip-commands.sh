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

ENV_FILE="${SHARED_DIR}/eip.env"
RUN_ID_FILE="${SHARED_DIR}/eip-run-id"
LIB_FILE="${SHARED_DIR}/deterministic-lb-eip-lib.sh"
EIP_ALLOCATION_ID=""
EIP_ASSOCIATION=""
RUN_ID=""

if [[ ! -f "${LIB_FILE}" ]]; then
    echo "missing shared EIP helpers at ${LIB_FILE}; nothing to release"
    exit 0
fi
# shellcheck source=/dev/null
source "${LIB_FILE}"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

# The run identity is written before allocation, so it also covers the window
# between a successful allocation and writing eip.env. Without it, there is no
# proof that an allocation belongs to this execution.
if [[ -f "${RUN_ID_FILE}" ]]; then
    RUN_ID=$(cat "${RUN_ID_FILE}")
elif [[ -n "${HYPERSHIFT_E2E_RUN_ID:-}" ]]; then
    RUN_ID="${HYPERSHIFT_E2E_RUN_ID}"
elif [[ -n "${PROW_JOB_ID:-}" ]]; then
    RUN_ID="${PROW_JOB_ID}"
else
    echo "no EIP run identity found; nothing to release"
    exit 0
fi

if [[ -z "${RUN_ID}" ]]; then
    echo "could not determine a unique EIP run identity" >&2
    exit 2
fi

if [[ -z "${MGMT_REGION:-}" ]]; then
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "no eip.env and no management kubeconfig; nothing to release"
        exit 0
    fi
    if ! MGMT_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}'); then
        echo "could not discover the management cluster AWS region" >&2
        exit 2
    fi
fi
if [[ -z "${MGMT_REGION:-}" ]]; then
    echo "could not discover the management cluster AWS region" >&2
    exit 2
fi

if [[ -n "${EIP_ALLOCATION_ID:-}" && "${EIP_ALLOCATION_ID}" != "None" ]]; then
    rc=0
    verify_run_eip "${EIP_ALLOCATION_ID}" || rc=$?
    if [[ $rc -eq 2 ]]; then
        echo "EIP ${EIP_ALLOCATION_ID} is already released"
        exit 0
    elif [[ $rc -ne 0 ]]; then
        exit 1
    fi
else
    if ! EIP_ALLOCATION_ID=$(find_run_eip); then
        exit 1
    fi
fi

if [[ -z "${EIP_ALLOCATION_ID}" ]]; then
    echo "no EIP owned by run ${RUN_ID}; nothing to release"
    exit 0
fi

for _ in $(seq 1 60); do
    if ! EIP_ASSOCIATION=$(aws_cmd ec2 describe-addresses --allocation-ids "${EIP_ALLOCATION_ID}" \
        --query 'Addresses[0].AssociationId' --output text 2>&1); then
        if [[ "${EIP_ASSOCIATION}" == *InvalidAllocationID.NotFound* ]]; then
            echo "EIP ${EIP_ALLOCATION_ID} is already released"
            exit 0
        fi
        echo "failed to describe EIP ${EIP_ALLOCATION_ID}: ${EIP_ASSOCIATION}" >&2
        exit 1
    fi
    if [[ -z "${EIP_ASSOCIATION}" || "${EIP_ASSOCIATION}" == "None" ]]; then
        break
    fi
    sleep 10
done
if [[ -n "${EIP_ASSOCIATION:-}" && "${EIP_ASSOCIATION}" != "None" ]]; then
    echo "refusing to release ${EIP_ALLOCATION_ID}: still associated to ${EIP_ASSOCIATION}" >&2
    exit 1
fi

if ! RELEASE_OUTPUT=$(aws_cmd ec2 release-address --allocation-id "${EIP_ALLOCATION_ID}" 2>&1); then
    if [[ "${RELEASE_OUTPUT}" == *InvalidAllocationID.NotFound* ]]; then
        echo "EIP ${EIP_ALLOCATION_ID} is already released"
        exit 0
    fi
    echo "failed to release EIP ${EIP_ALLOCATION_ID}: ${RELEASE_OUTPUT}" >&2
    exit 1
fi
echo "released EIP ${EIP_ALLOCATION_ID} for run ${RUN_ID}"
