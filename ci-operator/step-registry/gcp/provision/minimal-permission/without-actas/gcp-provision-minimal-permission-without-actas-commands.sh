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

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

iam_account="ipi-min-perm-without-actAs-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts keys create "${SHARED_DIR}/gcp_min_permissions_without_actas.json" --iam-account="${iam_account}" || exit 1
echo "$(date -u --rfc-3339=seconds) - Created a temporary key of the IAM service account, which hasn't the 'iam.serviceAccounts.actAs' permission, for GCP minimum permissions testing."
