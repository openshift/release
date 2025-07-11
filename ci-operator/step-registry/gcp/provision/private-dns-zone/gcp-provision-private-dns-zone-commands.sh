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
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

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
if [[ -n "${BASE_DOMAIN}" ]]; then
  GCP_BASE_DOMAIN="${BASE_DOMAIN}"
fi

CLUSTER_PVTZ_PROJECT="${GCP_PROJECT}"
if [[ -n "${PRIVATE_ZONE_PROJECT}" ]]; then
  CLUSTER_PVTZ_PROJECT="${PRIVATE_ZONE_PROJECT}"
fi
private_zone_name="${CLUSTER_NAME}-$RANDOM-priv-zone"

if [[ "${PRE_CREATE_PRIVATE_ZONE}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Pre-creating the DNS private zone in '${CLUSTER_PVTZ_PROJECT}' project..."

  if test -f "${SHARED_DIR}/customer_vpc_subnets.yaml"; then
    echo "$(date -u --rfc-3339=seconds) - Reading variables from customer_vpc_subnets.yaml..."
    NETWORK=$(yq-go r "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.gcp.network')
  else
    echo "$(date -u --rfc-3339=seconds) - Reading variables from xpn_project_setting.json..."
    NETWORK=$(jq -r '.clusterNetwork' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
  fi

  gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones create "${private_zone_name}" --description "Pre-created private DNS zone" --visibility "private" --dns-name "${CLUSTER_NAME}.${GCP_BASE_DOMAIN%.}." --networks "${NETWORK}"
  cat > "${SHARED_DIR}/private-dns-zone-destroy.sh" << EOF
gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones delete -q ${private_zone_name}
EOF
else
  echo "$(date -u --rfc-3339=seconds) - Skip pre-creating the DNS private zone in '${CLUSTER_PVTZ_PROJECT}' project."
fi

echo "${private_zone_name}" > "${SHARED_DIR}/cluster-pvtz-zone-name"
