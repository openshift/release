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

# See https://docs.openshift.com/container-platform/4.12/installing/installing_gcp/installing-gcp-account.html#minimum-required-permissions-ipi-gcp_installing-gcp-account
# There are pre-configured 2 IAM service accounts, along with some custom roles.
# The IAM service account for IPI: ipi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com
# The IAM service account for UPI: upi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com
# Currently we only deal with IPI in Prow CI.
iam_account="ipi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts keys create "${SHARED_DIR}/gcp_min_permissions.json" --iam-account="${iam_account}" || exit 1
echo "$(date -u --rfc-3339=seconds) - Created a temporary key of the IAM service account for the minimum permissions testing on GCP."
