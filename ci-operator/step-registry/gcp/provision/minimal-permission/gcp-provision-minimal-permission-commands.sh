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

# jiwei-debug
if [[ "${GOOGLE_PROJECT_ID}" =~ openshift-gce-devel ]]; then
  role_name="installer_qe_minimal_permissions"
  gcloud iam roles describe --project "${GOOGLE_PROJECT_ID}" "${role_name}" || echo "The custom role '${role_name}' does not exist."
fi

# See https://docs.openshift.com/container-platform/4.12/installing/installing_gcp/installing-gcp-account.html#minimum-required-permissions-ipi-gcp_installing-gcp-account
# There are pre-configured 2 IAM service accounts, along with some custom roles.
# The IAM service account for IPI: ipi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com
# The IAM service account for UPI: upi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com
# Currently we only deal with IPI in Prow CI.
iam_account="ipi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com"

email=$(gcloud --project "${GOOGLE_PROJECT_ID}" iam service-accounts list --filter="email=${iam_account}" --format='value(email)')
if [[ -z "${email}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to find the IAM service account '${iam_account}' in GCP project '${GOOGLE_PROJECT_ID}', abort."
  exit 1
fi

gcloud --project "${GOOGLE_PROJECT_ID}" iam service-accounts keys create "${SHARED_DIR}/gcp_min_permissions.json" --iam-account="${iam_account}" || exit 1
echo "$(date -u --rfc-3339=seconds) - Created a temporary key of the IAM service account for the minimum permissions testing on GCP."

echo "$(date -u --rfc-3339=seconds) - Check the IAM service account's roles/permissions..."

gcloud projects get-iam-policy "${GOOGLE_PROJECT_ID}" --flatten='bindings[].members' --format='table(bindings.role)' --filter="bindings.members:${iam_account}"

readarray -t binding_roles < <(gcloud projects get-iam-policy "${GOOGLE_PROJECT_ID}" --flatten='bindings[].members' --format='table(bindings.role)' --filter="bindings.members:${iam_account}" | grep roles)
for role in "${binding_roles[@]}"; do
  if [[ "${role}" =~ "projects/" ]]; then
    # Example: projects/openshift-qe/roles/jiwei_compute_admin
    project=$(echo "${role}" | awk -F/ '{print $2}')
    role_name=$(echo "${role}" | awk -F/ '{print $4}')
    CMD="gcloud iam roles describe --project=${project} ${role_name}"
  else
    # Example: roles/compute.admin
    CMD="gcloud iam roles describe ${role}"
  fi
  echo "Running Command: ${CMD}"
  eval "${CMD}"
done
