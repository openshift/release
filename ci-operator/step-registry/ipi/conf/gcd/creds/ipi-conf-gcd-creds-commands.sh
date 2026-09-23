#!/bin/bash

set -euo pipefail

CRED_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
if [[ ! -f "${CRED_FILE}" ]]; then
  echo "ERROR: Credential file not found at ${CRED_FILE}"
  exit 1
fi

CRED_TYPE=$(jq -er '.type' "${CRED_FILE}" 2>/dev/null) || {
  echo "ERROR: Invalid credential file at ${CRED_FILE}"
  exit 1
}

echo "GCD configuration validated"
echo "  Credential type: ${CRED_TYPE}"
