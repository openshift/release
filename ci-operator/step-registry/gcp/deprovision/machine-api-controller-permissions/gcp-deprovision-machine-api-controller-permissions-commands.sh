#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

if ! test -f "${SHARED_DIR}/mac_permissions"; then
  echo "Failed to find '${SHARED_DIR}/mac_permissions', aborted." && exit 1
fi

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

function backoff() {
  local attempt=0
  local failed=0
  echo "INFO: Running Command '$*'"
  while true; do
    eval "$*" && failed=0 || failed=1
    if [[ $failed -eq 0 ]]; then
      break
    fi
    attempt=$(( attempt + 1 ))
    if [[ $attempt -gt 5 ]]; then
      break
    fi
    echo "command failed, retrying in $(( 2 ** attempt )) seconds"
    sleep $(( 2 ** attempt ))
  done
  return $failed
}

echo "INFO: Start removing the permissions from the Machine-Api-Controller (MAC) service accounts..."

sed -i 's/add-iam-policy-binding/remove-iam-policy-binding/g' "${SHARED_DIR}/mac_permissions"
cat "${SHARED_DIR}/mac_permissions"

while IFS= read -r line
do
  backoff "$line"
done < "${SHARED_DIR}/mac_permissions"
