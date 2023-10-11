#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Log in
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_URL} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_URL}" --token "${OCM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OCM_TOKEN!"
  exit 1
fi

# Configure gcloud
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

REGION="${LEASED_RESOURCE}"
echo "Using region: ${REGION}"

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_NAME=$(ocm describe cluster $CLUSTER_ID --json | jq -r '.name')
echo "Updating firewall rules for data-path test on cluster $CLUSTER_NAME"

NETWORK_NAME=$(gcloud compute networks list --format="value(name)" | grep ^${CLUSTER_NAME})
gcloud compute firewall-rules create ${NETWORK_NAME}-net --network ${NETWORK_NAME} --direction INGRESS --priority 101 --description 'allow tcp,udp network tests' --rules tcp:10000-20000,udp:10000-20000 --action allow



