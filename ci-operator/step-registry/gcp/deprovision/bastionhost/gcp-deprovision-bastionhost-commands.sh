#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/bastion-destroy.sh" ]; then
  echo "No 'bastion-destroy.sh' found, aborted." && exit 0
fi

if [[ -s "${SHARED_DIR}/xpn.json" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/xpn_creds.json" ]]; then
  echo "Activating XPN service-account..."
  GOOGLE_CLOUD_XPN_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/xpn_creds.json"
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_XPN_KEYFILE_JSON}"
fi
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

## Destroying DNS resources of mirror registry
if [[ -f "${SHARED_DIR}/mirror-dns-destroy.sh" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Destroying DNS resources of mirror registry..."
  sh "${SHARED_DIR}/mirror-dns-destroy.sh"
fi

## Destroy the SSH bastion
echo "$(date -u --rfc-3339=seconds) - Destroying the bastion host..."
sh "${SHARED_DIR}/bastion-destroy.sh"
