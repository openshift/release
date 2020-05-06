#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
gcloud config set project "$(jq -r .gcp.projectID ${SHARED_DIR}/metadata.json)"

echo "Deleting gcloud deployments..."

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
set +e
gcloud deployment-manager deployments delete -q ${INFRA_ID}-bootstrap
set -e
gcloud deployment-manager deployments delete -q ${INFRA_ID}-{worker,control-plane,security,infra,vpc}
