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

python3 --version 
export CLOUDSDK_PYTHON=python3

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

function backoff() {
  local attempt=0
  local failed=0
  echo "INFO: Running Command '$*'"
  while true; do
    eval "$*" && failed=0 || failed=1
    if [[ $failed -eq 0 ]]; then
      break
    fi
    attempt=$(( attempt + 1 ))
    if [[ $attempt -gt 5 ]]; then
      break
    fi
    echo "command failed, retrying in $(( 2 ** attempt )) seconds"
    sleep $(( 2 ** attempt ))
  done
  return $failed
}

readarray -t iam_accounts < <(gcloud iam service-accounts list --filter="displayName~${CLUSTER_NAME}" --format='value(email)')

for sa_email in "${iam_accounts[@]}"; do
  display_name=$(gcloud iam service-accounts describe "${sa_email}" --format=json | jq -r .displayName)
  echo "INFO: email '${sa_email}' displayName '${display_name}'"
  if [[ "${display_name}" =~ openshift-gcp-ccm ]]; then
    echo "INFO: Updating the permissions for the CCM SA '${sa_email}'..."
    readarray -t ccm_existing_roles < <(gcloud projects get-iam-policy ${GOOGLE_PROJECT_ID} --flatten='bindings[].members' --format='value(bindings.role)' --filter="bindings.members:${sa_email}")
    for role in "${ccm_existing_roles[@]}"; do
      cmd="gcloud projects remove-iam-policy-binding ${GOOGLE_PROJECT_ID} --member \"serviceAccount:${sa_email}\" --role \"${role}\" 1>/dev/null"
      backoff "${cmd}"
    done
    cmd="gcloud projects add-iam-policy-binding ${GOOGLE_PROJECT_ID} --member \"serviceAccount:${sa_email}\" --role \"projects/${GOOGLE_PROJECT_ID}/roles/${CCM_NEW_ROLE}\" 1>/dev/null"
    backoff "${cmd}"
    echo "$cmd" >>"${SHARED_DIR}/ccm_permissions"
    break
  fi
done

echo "INFO: The IAM service accounts roles after updating..."
for sa_email in "${iam_accounts[@]}"; do
  cmd="gcloud projects get-iam-policy ${GOOGLE_PROJECT_ID} --flatten='bindings[].members' --format='table(bindings.role)' --filter='bindings.members:${sa_email}'"
  echo "INFO: Running Command '${cmd}'"
  eval "${cmd}"
done
