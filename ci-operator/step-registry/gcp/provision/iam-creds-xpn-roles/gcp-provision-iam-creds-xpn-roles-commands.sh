#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

echo "Reading variables from 'xpn_project_setting.json'..."
HOST_PROJECT=$(jq -r '.hostProject' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")

function backoff() {
  local attempt=0
  local failed=0
  while true; do
    "$@" && failed=0 || failed=1
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

failed=0

echo "INFO: Start granting the required roles/permissions to the IAM service accounts in GCP host project..."
readarray -t iam_accounts < <(gcloud iam service-accounts list --filter="displayName~${CLUSTER_NAME}" --format='table(email)' | grep -v EMAIL)

for sa_email in "${iam_accounts[@]}"; do
  display_name=$(gcloud iam service-accounts describe "${sa_email}" --format=json | jq -r .displayName)
  echo "INFO: email '${sa_email}' displayName '${display_name}'"
  if [[ "${display_name}" =~ openshift-(machine-a|cloud-network-config) ]]; then
    echo "INFO: Granting 'roles/compute.networkUser' to '${sa_email}'..."
    cmd="gcloud projects add-iam-policy-binding ${HOST_PROJECT} --member \"serviceAccount:${sa_email}\" --role 'roles/compute.networkUser' 1>/dev/null"
    backoff "${cmd}" && failed=0 || failed=1
    if [ $failed -ne 0 ]; then
      echo "ERROR: Failed granting 'roles/compute.networkUser' to '${sa_email}'..."  && exit $failed
    fi
    echo "$cmd" >>"${SHARED_DIR}/iam_creds_xpn_roles"
  elif [[ "${display_name}" =~ openshift-ingre ]]; then
    echo "INFO" "Granting 'dns.networks.bindPrivateDNSZone' to '${sa_email}'..."
    cmd="gcloud projects add-iam-policy-binding ${HOST_PROJECT} --member \"serviceAccount:${sa_email}\" --role \"projects/${HOST_PROJECT}/roles/dns.networks.bindPrivateDNSZone\" 1>/dev/null"
    backoff "${cmd}" && failed=0 || failed=1
    if [ $failed -ne 0 ]; then
      echo "ERROR: Failed granting 'dns.networks.bindPrivateDNSZone' (custom role) to '${sa_email}'..."  && exit $failed
    fi
    echo "$cmd" >>"${SHARED_DIR}/iam_creds_xpn_roles"
  fi
done

echo "INFO" "The IAM service accounts roles..."
for sa_email in "${iam_accounts[@]}"; do
  cmd="gcloud projects get-iam-policy ${GOOGLE_PROJECT_ID} --flatten='bindings[].members' --format='table(bindings.role)' --filter='bindings.members:${sa_email}'"
  eval "${cmd}"

  cmd="gcloud projects get-iam-policy ${HOST_PROJECT} --flatten='bindings[].members' --format='table(bindings.role)' --filter='bindings.members:${sa_email}'"
  eval "${cmd}"
done

echo "INFO: Exit code '$failed'."
exit $failed
