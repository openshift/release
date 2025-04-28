#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

if test -f "${SHARED_DIR}/customer_vpc_subnets.yaml"; then
  echo "Reading variables from customer_vpc_subnets.yaml..."
  NETWORK=$(yq-go r "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.gcp.network')
else
  echo "Reading variables from xpn_project_setting.json..."
  NETWORK=$(jq -r '.clusterNetwork' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GCP_PROJECT}"
fi

gcloud dns managed-zones create "${CLUSTER_NAME}-private-zone" --description "Pre-created private DNS zone" --visibility "private" --dns-name "${CLUSTER_NAME}.${GCP_BASE_DOMAIN}." --networks "${NETWORK}"
cat > "${SHARED_DIR}/private-dns-zone-destroy.sh" << EOF
gcloud dns managed-zones delete -q ${CLUSTER_NAME}-private-zone
EOF

echo "${GCP_PROJECT}" > "${SHARED_DIR}/cluster-pvtz-project"
