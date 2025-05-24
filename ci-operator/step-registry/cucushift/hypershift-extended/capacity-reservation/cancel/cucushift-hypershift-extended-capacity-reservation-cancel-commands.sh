#!/usr/bin/env bash

set -euo pipefail

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

export AWS_GUEST_INFRA_CREDENTIALS_FILE
if [[ -f "${SHARED_DIR}/reservation_id" && -n "${NODEPOOL_CAPACITY_RESERVATION}" ]]; then
    RESERVATION_ID=$(cat ${SHARED_DIR}/reservation_id | jq -r .${NODEPOOL_CAPACITY_RESERVATION})
    aws ec2 cancel-capacity-reservation --capacity-reservation-id ${RESERVATION_ID}
fi
