#!/usr/bin/env bash

set -euo pipefail

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

export AWS_GUEST_INFRA_CREDENTIALS_FILE
CR_OUTPUT_FILE=${SHARED_DIR}/reservation_details.json

aws ec2 create-capacity-reservation \
    --availability-zone ${HYPERSHIFT_HC_ZONES} \
    --instance-type ${ADDITIONAL_HYPERSHIFT_INSTANCE_TYPE} \
    --instance-count ${ADDITIONAL_HYPERSHIFT_NODE_COUNT} \
    --instance-platform ${OPERATING_SYSTEM} \
    --instance-match-criteria targeted \
    --end-date-type "unlimited" \
    > ${CR_OUTPUT_FILE}

RESERVATION_ID=$(jq -r '.CapacityReservation.CapacityReservationId' "${CR_OUTPUT_FILE}")
echo ${RESERVATION_ID} > ${SHARED_DIR}/reservation_id
