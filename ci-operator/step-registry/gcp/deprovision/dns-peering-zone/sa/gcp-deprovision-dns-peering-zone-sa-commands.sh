#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

function backoff() {
  local attempt=0
  local failed=0
  echo "INFO: Running Command '$*'"
  while true; do
    eval "$@" && failed=0 || failed=1
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

missing_roles_dns_admin_project=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" missingRolesDnsAdmin)
missing_roles_dns_peer_project=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" missingRolesDnsPeer)
if [[ -z "${missing_roles_dns_admin_project}" ]] && [[ -z "${missing_roles_dns_peer_project}" ]]; then
  echo "Nothing to do."
  exit 0
fi

dns_sa=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" serviceAccount)

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

if [[ -n "${missing_roles_dns_admin_project}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: remove the role binding 'roles/dns.admin' in project '${missing_roles_dns_admin_project}' for the service account '${dns_sa}'..."
  cmd="gcloud projects remove-iam-policy-binding ${missing_roles_dns_admin_project} --member \"serviceAccount:${dns_sa}\" --role roles/dns.admin 1> /dev/null"
  backoff "${cmd}"
fi
if [[ -n "${missing_roles_dns_peer_project}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: remove the role binding 'roles/dns.peer' in project '${missing_roles_dns_peer_project}' for the service account '${dns_sa}'..."
  cmd="gcloud projects remove-iam-policy-binding ${missing_roles_dns_peer_project} --member \"serviceAccount:${dns_sa}\" --role roles/dns.peer 1> /dev/null"
  backoff "${cmd}"
fi
