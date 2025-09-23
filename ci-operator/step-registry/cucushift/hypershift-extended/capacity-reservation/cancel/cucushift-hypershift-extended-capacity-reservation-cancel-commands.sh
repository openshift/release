#!/usr/bin/env bash
set -e
set -x

AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
AWS_DEFAULT_REGION=${HYPERSHIFT_AWS_REGION}

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

export AWS_DEFAULT_REGION
export AWS_SHARED_CREDENTIALS_FILE
if [[ -f "${SHARED_DIR}/reservation_id" && -n "${NODEPOOL_CAPACITY_RESERVATION}" ]]; then
    RESERVATION_ID=$(cat ${SHARED_DIR}/reservation_id)
    aws ec2 cancel-capacity-reservation --capacity-reservation-id ${RESERVATION_ID}
fi
