#!/bin/bash
set -euo pipefail

CLUSTER_NAME_FILE="${SHARED_DIR}/QUAY_GEOREP_CLUSTER_B_NAME"
if [[ ! -s "${CLUSTER_NAME_FILE}" ]]; then
    echo "No cluster B name found in SHARED_DIR; skipping cleanup." >&2
    exit 0
fi

CLUSTER_NAME="$(cat "${CLUSTER_NAME_FILE}")"
echo "Destroying HyperShift hosted cluster '${CLUSTER_NAME}'..." >&2

QUAY_AWS_ACCESS_KEY="$(cat /var/run/quay-qe-aws-secret/access_key)"
QUAY_AWS_SECRET_KEY="$(cat /var/run/quay-qe-aws-secret/secret_key)"
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

# TODO: Replace with actual hypershift CLI invocation.
#
# hypershift destroy cluster aws \
#   --name "${CLUSTER_NAME}" \
#   --aws-creds /var/run/quay-qe-aws-secret/credentials \
#   --destroy-cloud-resources

echo "PLACEHOLDER: HyperShift cluster destruction not yet implemented" >&2
