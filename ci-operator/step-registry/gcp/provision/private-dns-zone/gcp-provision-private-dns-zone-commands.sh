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

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GCP_PROJECT}"
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"

if [[ "${PRIVATE_ZONE_PROJECT_TYPE}" == "service-project" ]]; then
  echo "$(date -u --rfc-3339=seconds) - The DNS private zone will be in service project (i.e. where the cluster resources are deployed). "
  CLUSTER_PVTZ_PROJECT="${GCP_PROJECT}"
elif [[ "${PRIVATE_ZONE_PROJECT_TYPE}" == "host-project" ]]; then
  echo "$(date -u --rfc-3339=seconds) - The DNS private zone will be in host project (i.e. where the cluster's network resources are configured). "
  CLUSTER_PVTZ_PROJECT=$(jq -r '.hostProject' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
elif [[ "${PRIVATE_ZONE_PROJECT_TYPE}" == "third-project" ]]; then
  echo "$(date -u --rfc-3339=seconds) - The DNS private zone, along with the base domain, will be in the third project (i.e. another service project where DNS resources are configured). "
  if [[ ! -f "${CLUSTER_PROFILE_DIR}/third_project_setting.json" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the 'third_project_setting.json' in CLUSTER_PROFILE_DIR, abort." && exit 1
  fi
  CLUSTER_PVTZ_PROJECT=$(jq -r '.project' "${CLUSTER_PROFILE_DIR}/third_project_setting.json")
  GCP_BASE_DOMAIN=$(jq -r '.baseDomain' "${CLUSTER_PROFILE_DIR}/third_project_setting.json")
else
  echo "$(date -u --rfc-3339=seconds) - ERROR: Unknown private zone project type '${PRIVATE_ZONE_PROJECT_TYPE}', abort. " && exit 1
fi

if [[ "${CREATE_PRIVATE_ZONE}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Pre-creating the DNS private zone in '${CLUSTER_PVTZ_PROJECT}' project..."

  if test -f "${SHARED_DIR}/customer_vpc_subnets.yaml"; then
    echo "$(date -u --rfc-3339=seconds) - Reading variables from customer_vpc_subnets.yaml..."
    NETWORK=$(yq-go r "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.gcp.network')
  else
    echo "$(date -u --rfc-3339=seconds) - Reading variables from xpn_project_setting.json..."
    NETWORK=$(jq -r '.clusterNetwork' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
  fi

  gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones create "${CLUSTER_NAME}-private-zone" --description "Pre-created private DNS zone" --visibility "private" --dns-name "${CLUSTER_NAME}.${GCP_BASE_DOMAIN%.}." --networks "${NETWORK}"
  cat > "${SHARED_DIR}/private-dns-zone-destroy.sh" << EOF
  gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones delete -q ${CLUSTER_NAME}-private-zone
EOF
else
  echo "$(date -u --rfc-3339=seconds) - Skip pre-creating the DNS private zone in '${CLUSTER_PVTZ_PROJECT}' project."
fi

echo "${CLUSTER_PVTZ_PROJECT}" > "${SHARED_DIR}/cluster-pvtz-project"
