#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

if [[ "${CREATE_PRIVATE_ZONE}" == "no" ]]; then
  echo "$(date -u --rfc-3339=seconds) - No pre-created DNS private zone involved, nothing to do. "
  exit 0
fi

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

ret=0

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
CLUSTER_PVTZ_PROJECT="$(< ${SHARED_DIR}/cluster-pvtz-project)"

if [[ "${CREATE_PRIVATE_ZONE}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - The cluster uses a pre-create DNS private zone, checking its existance after the cluster is destroyed..."
  readarray -t zones < <(gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones list --filter="visibility=private AND name~${CLUSTER_NAME}" --format='value(name)')
  if [[ "${#zones[@]}" -eq 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Failed to find the pre-create DNS private zone in project ${CLUSTER_PVTZ_PROJECT}."
    ret=1
  fi
fi

exit $ret