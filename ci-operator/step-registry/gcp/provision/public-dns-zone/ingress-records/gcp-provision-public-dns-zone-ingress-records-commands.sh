#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GCP_PROJECT}"
fi

ROUTER_IP=$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')
CMD="gcloud --project ${BASE_DOMAIN_ZONE_PROJECT} dns record-sets create *.apps.${CLUSTER_NAME}.${BASE_DOMAIN%.}. --rrdatas=${ROUTER_IP} --ttl 300 --type A --zone ${BASE_DOMAIN_ZONE_NAME}"
echo "${CMD}"
eval "${CMD}"

cat > "${SHARED_DIR}/ingress-records-destroy.sh" << EOF
gcloud --project ${BASE_DOMAIN_ZONE_PROJECT} dns record-sets delete -q *.apps.${CLUSTER_NAME}.${BASE_DOMAIN%.}. --type A --zone ${BASE_DOMAIN_ZONE_NAME}
EOF
