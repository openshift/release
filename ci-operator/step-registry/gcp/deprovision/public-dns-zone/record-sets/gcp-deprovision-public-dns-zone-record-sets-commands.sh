#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/record-sets-destroy.sh" ]; then
  echo "No 'record-sets-destroy.sh' found, aborted." && exit 0
fi

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gcp-dns-admin.json"
project_id=$(jq -r '.project_id' "${CLUSTER_PROFILE_DIR}/gcp-dns-admin.json")
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${project_id}"
fi

## Destroy the private DNS zone
echo "$(date -u --rfc-3339=seconds) - Destroying DNS record..."
sh "${SHARED_DIR}/record-sets-destroy.sh"
