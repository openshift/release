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

# See https://docs.openshift.com/container-platform/4.12/installing/installing_gcp/installing-gcp-account.html#minimum-required-permissions-ipi-gcp_installing-gcp-account
# There are pre-configured 2 IAM service accounts, along with some custom roles.
# The IAM service account for IPI: ipi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com
# The IAM service account for UPI: upi-min-permissions-sa@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com
# Currently we only deal with IPI in Prow CI.
if [[ "${GCP_INSTALL_USE_MINIMAL_PERMISSIONS}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Going to use the IAM service account of general minimal permissions"
  sa_filename="ipi-min-permissions-sa.json"
elif [[ "${MINIMAL_PERMISSIONS_WITHOUT_ACT_AS}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Going to use the IAM service account of general minimal permissions, and without 'iam.serviceAccounts.actAs'"
  sa_filename="ipi-min-perm-without-actAs-sa.json"
elif [[ "${GCP_CCO_MANUAL_USE_MINIMAL_PERMISSIONS}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Going to use the IAM service account of minimal permissions for CCO in Manual mode"
  sa_filename="ipi-xpn-cco-manual-permissions.json"
elif [[ "${MINIMAL_PERMISSIONS_WITHOUT_FIREWALL_PROVISION}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Going to use the IAM service account of general minimal permissions, and without 'compute.firewalls.create' & 'compute.firewalls.delete' permissions"
  sa_filename="ipi-min-perm-no-fw-sa.json"
elif [[ "${MINIMAL_PERMISSIONS_CCO_MANUAL_WITHOUT_FIREWALL_PROVISION}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Going to use the IAM service account of minimal permissions for CCO in Manual mode, and without 'compute.firewalls.create' & 'compute.firewalls.delete' permissions"
  sa_filename="ipi-cco-manual-no-fw-sa.json"
else
  echo "$(date -u --rfc-3339=seconds) - Not miminal permissions testing, going to use the deafult IAM service account."
  exit 0
fi

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

if [ -f "${CLUSTER_PROFILE_DIR}/${sa_filename}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Use pre-configured key of the IAM service account for the minimum permissions testing on GCP."
  cp "${CLUSTER_PROFILE_DIR}/${sa_filename}" "${SHARED_DIR}/gcp_min_permissions.json"
else
  echo "$(date -u --rfc-3339=seconds) - Failed to find the pre-configured key file of the IAM service account for the minimum permissions testing on GCP, abort." && exit 1
fi

iam_account=$(jq -r .client_email "${CLUSTER_PROFILE_DIR}/${sa_filename}")
email=$(gcloud iam service-accounts list --filter="email=${iam_account}" --format='value(email)')
if [[ -z "${email}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to find the IAM service account '${iam_account}' in GCP project '${GOOGLE_PROJECT_ID}', abort." && exit 1
fi

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
