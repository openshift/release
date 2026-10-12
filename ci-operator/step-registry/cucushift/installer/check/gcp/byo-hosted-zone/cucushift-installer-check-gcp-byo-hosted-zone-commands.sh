#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
GCP_BASE_DOMAIN="$(grep "baseDomain:" ${SHARED_DIR}/install-config.yaml | awk '{print $2}')"
echo "$(date -u --rfc-3339=seconds) - INFO: '${CLUSTER_NAME}.${GCP_BASE_DOMAIN}.'"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

ret=0
tmp_out=$(mktemp)

CLUSTER_PVTZ_PROJECT="${GOOGLE_PROJECT_ID}"
if [[ -n "${PRIVATE_ZONE_PROJECT}" ]]; then
  CLUSTER_PVTZ_PROJECT="${PRIVATE_ZONE_PROJECT}"
fi
private_zone_name="$(< ${SHARED_DIR}/cluster-pvtz-zone-name)"

echo "$(date -u --rfc-3339=seconds) - INFO: Listing the record-sets of the cluster's DNS private zone..."
gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns record-sets list --zone "${private_zone_name}" | tee "${tmp_out}"
if grep -q "api\.${CLUSTER_NAME}\.${GCP_BASE_DOMAIN}\." "${tmp_out}"; then
  echo "$(date -u --rfc-3339=seconds) - INFO: The API record-set is present."
else
  echo "$(date -u --rfc-3339=seconds) - ERROR: The API record-set is absent."
  ret=1
fi
if grep -q "api-int\.${CLUSTER_NAME}\.${GCP_BASE_DOMAIN}\." "${tmp_out}"; then
  echo "$(date -u --rfc-3339=seconds) - INFO: The API-INT record-set is present."
else
  echo "$(date -u --rfc-3339=seconds) - ERROR: The API-INT record-set is absent."
  ret=1
fi
if grep -q "\*\.apps\.${CLUSTER_NAME}\.${GCP_BASE_DOMAIN}\." "${tmp_out}"; then
  echo "$(date -u --rfc-3339=seconds) - INFO: The *.APPS record-set is present."
else
  echo "$(date -u --rfc-3339=seconds) - ERROR: The *.APPS record-set is absent."
  ret=1
fi

rm -f "${tmp_out}"
exit $ret