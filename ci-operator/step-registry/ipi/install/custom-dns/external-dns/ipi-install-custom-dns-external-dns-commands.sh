#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Setting external DNS for custom-dns"

# Installing required tools
#
mkdir /tmp/bin
echo "## Install jq"
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
echo "   jq installed"
export PATH=$PATH:/tmp/bin

workdir="/tmp/installer"
mkdir -p "${workdir}"
pushd "${workdir}"

if [ ! -d "$(${workdir}/google-cloud-sdk)" ]; then
  echo "$(date -u --rfc-3339=seconds) - Downloading 'gcloud' as it's not intalled..."
  curl https://sdk.cloud.google.com > install.sh
  bash install.sh --disable-prompts --install-dir=${workdir}
  echo "Completed gcloud installation"
  export PATH=$PATH:/tmp/bin:${workdir}/google-cloud-sdk/bin
else
  echo "$(date -u --rfc-3339=seconds) - gcloud already intalled..."
fi
gcloud version

echo "shared_dir=${SHARED_DIR}"
INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"
echo "infra_id=${INFRA_ID}"

#export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
#gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
#gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"

echo "$(date -u --rfc-3339=seconds) - Finished activating gcloud service account"

api_ip_address=$(gcloud compute forwarding-rules describe --global "${INFRA_ID}-apiserver" --format json | jq -r .IPAddress)
if [[ -z "${api_ip_address}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the API forwarding-rule."
fi

echo "api_ip_address=${api_ip_address}"
