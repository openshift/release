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

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
CLUSTER_PVTZ_PROJECT="$(< ${SHARED_DIR}/cluster-pvtz-project)"

if [[ "${CLUSTER_PVTZ_PROJECT}" != "${GOOGLE_PROJECT_ID}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Ensure the cluster has no private zone in the current project..."
  readarray -t zones < <(gcloud --project "${GOOGLE_PROJECT_ID}" dns managed-zones list --filter="visibility=private AND name~${CLUSTER_NAME}" --format='value(name)')
  if [[ "${#zones[@]}" -gt 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected DNS private zone(s), '${zones[*]}', found in the current project. "
    ret=1
  fi
fi

gcloud --project "${CLUSTER_PVTZ_PROJECT}" dns managed-zones describe "${CLUSTER_NAME}-private-zone" --format=json > "${tmp_out}"
zone_description=$(jq -r .description "${tmp_out}")
# zone_dns_name=$(jq -r .dnsName "${tmp_out}")
if [[ "${CREATE_PRIVATE_ZONE}" == "yes" ]] && [[ "${zone_description}" != "Created By OpenShift Installer" ]]; then
  echo "$(date -u --rfc-3339=seconds) - A pre-create DNS private zone is in use."
elif [[ "${CREATE_PRIVATE_ZONE}" == "no" ]] && [[ "${zone_description}" == "Created By OpenShift Installer" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Installer provisioned DNS private zone is in use."
else
  echo "$(date -u --rfc-3339=seconds) - Something went wrong, CREATE_PRIVATE_ZONE '${CREATE_PRIVATE_ZONE}' and zone description '${zone_description}'."
  ret=1
fi

rm -f "${tmp_out}"
exit $ret