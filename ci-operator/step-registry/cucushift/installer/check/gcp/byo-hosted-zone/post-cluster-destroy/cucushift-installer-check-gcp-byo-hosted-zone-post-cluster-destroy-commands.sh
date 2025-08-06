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

if [[ "${PRE_CREATE_PRIVATE_ZONE}" == "no" ]]; then
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

CLUSTER_PVTZ_PROJECT="${GOOGLE_PROJECT_ID}"
if [[ -n "${PRIVATE_ZONE_PROJECT}" ]]; then
  CLUSTER_PVTZ_PROJECT="${PRIVATE_ZONE_PROJECT}"
fi
private_zone_name="$(< ${SHARED_DIR}/cluster-pvtz-zone-name)"

echo "$(date -u --rfc-3339=seconds) - The cluster uses a pre-create DNS private zone, checking its existance after the cluster is destroyed..."
readarray -t zones < <(gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones list --filter="visibility=private AND name=${private_zone_name}" --format='value(name)')
if [[ "${#zones[@]}" -eq 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to find the pre-create DNS private zone in project ${CLUSTER_PVTZ_PROJECT}."
  ret=1
else
  echo "$(date -u --rfc-3339=seconds) - The pre-created DNS private zone info:"
  gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones describe "${zones[0]}"
  gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns record-sets list --zone "${zones[0]}"
fi

exit $ret