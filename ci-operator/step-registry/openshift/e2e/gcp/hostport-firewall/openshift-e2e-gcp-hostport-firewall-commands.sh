#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Open the OTE host-port range on the cluster network (perfscale-gcp-data-path-fw pattern).
GOOGLE_PROJECT_ID="$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email "${GCP_SHARED_CREDENTIALS_FILE}")
if ! gcloud auth list --filter="status:ACTIVE" --format="value(account)" | grep -Fxq "${sa_email}"; then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo "Infra ID: ${INFRA_ID}"

echo "Opening 30000-32767 on network ${INFRA_ID}-network"
gcloud compute firewall-rules create "${INFRA_ID}-ote-hostports" \
  --network "${INFRA_ID}-network" --direction INGRESS --priority 101 \
  --rules tcp:30000-32767,udp:30000-32767 --action allow
