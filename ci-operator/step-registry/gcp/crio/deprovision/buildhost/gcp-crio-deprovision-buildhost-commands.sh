#!/bin/bash

set -xeuo pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

if [ ! -f "${SHARED_DIR}/destroy.sh" ]; then
  echo "No 'destroy.sh' found, aborted." && exit 0
fi

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

## Destroy the SSH bastion
echo "$(date -u --rfc-3339=seconds) - Destroying the server host..."
sh "${SHARED_DIR}/destroy.sh"
