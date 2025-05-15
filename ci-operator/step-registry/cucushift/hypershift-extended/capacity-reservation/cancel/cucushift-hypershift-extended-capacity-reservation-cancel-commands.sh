#!/usr/bin/env bash

set -euo pipefail

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

export AWS_GUEST_INFRA_CREDENTIALS_FILE

RESERVATION_ID=$(cat ${SHARED_DIR}/reservation_id)

aws ec2 cancel-capacity-reservation --capacity-reservation-id ${RESERVATION_ID}

MAX_ATTEMPTS=5
ATTEMPT=1
STATE=""
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  echo "Check the capacity reservation state in #$ATTEMPT: "
  STATE=$(aws ec2 describe-capacity-reservations \
    --capacity-reservation-ids ${RESERVATION_ID} \
    --query "CapacityReservations[0].State" \
    --output text 2>/dev/null)
  
  if [[ "$STATE" == "cancelled" || "$STATE" == "expired" ]]; then
    echo "Capacity reservation is cancelled successfully or expired"
    exit 0
  else
    echo "Capacity reservation current status is: $STATE, retry after 5s"
    sleep 5
  fi
  ATTEMPT=$((ATTEMPT + 1))
done

if [[ $ATTEMPT == 5 ]] && [[ "$STATE" != "cancelled" && "$STATE" != "expired" ]]; then
   echo "Capacity reservation can't be cancelled, please check"
   exit 1
fi

