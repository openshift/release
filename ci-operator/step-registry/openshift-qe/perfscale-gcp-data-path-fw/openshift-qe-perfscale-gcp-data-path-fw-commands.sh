#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM


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

CLUSTER_NAME=$(oc get infrastructure cluster -o json | jq -r '.status.apiServerURL' | awk -F.  '{print$2}')
echo "Updating firewall rules for data-path test on cluster $CLUSTER_NAME"

NETWORK_NAME=$(gcloud compute networks list --format="value(name)" | grep ^${CLUSTER_NAME})
gcloud compute firewall-rules create ${NETWORK_NAME}-net --network ${NETWORK_NAME} --direction INGRESS --priority 101 --description 'allow tcp,udp network tests' --rules tcp:10000-61000,udp:10000-61000 --action allow



