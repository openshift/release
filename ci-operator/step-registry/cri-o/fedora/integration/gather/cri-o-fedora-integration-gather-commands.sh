#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "gathering logs"
# shellcheck source=/dev/null
source "${SHARED_DIR}/env"

#####################################
###############Log In################
#####################################

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

mkdir -p "${HOME}"/.ssh
chmod 0700 "${HOME}"/.ssh

cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub

#####################################
#####################################

instance_name=$(<"${SHARED_DIR}/gcp-instance-ids.txt")

function getlogs() {
  echo "### Downloading logs..."
  gcloud compute scp --recurse --zone "${ZONE}" --recurse "${instance_name}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT
