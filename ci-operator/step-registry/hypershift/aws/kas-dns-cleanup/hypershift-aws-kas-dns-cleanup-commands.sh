#!/bin/bash
set -uo pipefail

# Best effort: a leftover DNS record must never turn a passing job red.
warn() {
  echo "WARNING: $*, leaving the record in place" >&2
  exit 0
}

if [[ ! -s "${SHARED_DIR}/kas_dns_name" ]]; then
  echo "No KAS DNS name recorded, nothing to clean up"
  exit 0
fi
KAS_DNS_NAME=$(cat "${SHARED_DIR}/kas_dns_name")

if [[ ! -s "${SHARED_DIR}/kas_dns_delete_batch.json" || ! -s "${SHARED_DIR}/kas_dns_zone_id" ]]; then
  echo "hypershift-aws-kas-dns-update never created a record for ${KAS_DNS_NAME}, nothing to clean up"
  exit 0
fi

# A Route53 DELETE has to describe the record set exactly as it was created. Rather than
# rebuilding it from a query here, use the batch hypershift-aws-kas-dns-update wrote out
# when it had all the values at hand.
HOSTED_ZONE_ID=$(cat "${SHARED_DIR}/kas_dns_zone_id")
echo "Deleting the Route53 CNAME record for ${KAS_DNS_NAME} from zone ${HOSTED_ZONE_ID}"

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if ! output=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${SHARED_DIR}/kas_dns_delete_batch.json" 2>&1); then
  # The record being gone already is a success, not a failure worth reporting.
  if grep -q 'InvalidChangeBatch\|not found' <<<"${output}"; then
    echo "No CNAME record for ${KAS_DNS_NAME} in zone ${HOSTED_ZONE_ID}, nothing to clean up"
    exit 0
  fi
  echo "${output}" >&2
  warn "failed to delete the CNAME record for ${KAS_DNS_NAME}"
fi

echo "Deleted the CNAME record for ${KAS_DNS_NAME}"
exit 0
