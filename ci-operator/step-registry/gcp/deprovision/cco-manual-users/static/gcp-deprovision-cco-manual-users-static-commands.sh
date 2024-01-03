#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

function backoff() {
  local attempt=0
  local failed=0
  echo "Running Command '$*'"
  while true; do
    eval "$@" && failed=0 || failed=1
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
  echo "Return with '$failed'"
  #return $failed
}

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GCP_SERVICE_ACCOUNT=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${GCP_SERVICE_ACCOUNT}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

echo "$(date -u --rfc-3339=seconds) - Deleting GCP IAM service accounts for CCO manual mode..."

readarray -t service_accounts < <(gcloud iam service-accounts list --filter="displayName~${CLUSTER_NAME}" --format='value(email)')
for service_account in "${service_accounts[@]}"; do
  echo "$(date -u --rfc-3339=seconds) - Processing '${service_account}'..."
  
  echo "$(date -u --rfc-3339=seconds) - Fetching bindings.role of the service account, and then trying to remove them..."
  readarray -t roles < <(gcloud projects get-iam-policy "${GOOGLE_PROJECT_ID}" --flatten='bindings[].members' --format='value(bindings.role)' --filter="bindings.members:${service_account}")
  for role in "${roles[@]}"; do
    cmd="gcloud projects remove-iam-policy-binding ${GOOGLE_PROJECT_ID} --member='serviceAccount:${service_account}' --role '${role}' 1>/dev/null"
    backoff "${cmd}"
  done

  echo "$(date -u --rfc-3339=seconds) - Deleting the service account..."
  gcloud iam service-accounts delete -q "${service_account}"
done

echo "$(date -u --rfc-3339=seconds) - Done."