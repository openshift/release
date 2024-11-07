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

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

ret=0

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

echo "$(date -u --rfc-3339=seconds) - INFO: reading variables from 'xpn_project_setting.json'..."
target_project=$(jq -r '.hostProject' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
target_network=$(jq -r '.clusterNetwork' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
target_network=$(basename ${target_network})
cat <<EOF >"${SHARED_DIR}/dns-peering-zone-settings.yaml"
targetProject: ${target_project}
targetNetwork: ${target_network}
EOF

echo "$(date -u --rfc-3339=seconds) - INFO: ensure the dns peering zone service account is ok..."
if [[ -n "${DNS_PEERING_ZONE_SA}" ]]; then
  dns_sa="${DNS_PEERING_ZONE_SA}"
else
  dns_sa="${sa_email}"
fi
cat <<EOF >>"${SHARED_DIR}/dns-peering-zone-settings.yaml"
serviceAccount: ${dns_sa}
EOF

cmd="gcloud iam service-accounts describe ${dns_sa}"
run_command "${cmd}" || ret=1
if [ ${ret} -gt 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: failed to find the service account '${dns_sa}', abort."
  exit ${ret}
fi

cmd="gcloud projects get-iam-policy ${GOOGLE_PROJECT_ID} --flatten='bindings[].members' --format='table(bindings.role)' --filter='bindings.members:${dns_sa}' | grep roles/dns.admin"
run_command "${cmd}" || ret=1
if [ ${ret} -gt 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: The service account is lack of role 'roles/dns.admin' in project '${GOOGLE_PROJECT_ID}', temporarily grant it..."
  cmd="gcloud projects add-iam-policy-binding ${GOOGLE_PROJECT_ID} --member \"serviceAccount:${dns_sa}\" --role roles/dns.admin 1> /dev/null"
  backoff "${cmd}"

  cat <<EOF >>"${SHARED_DIR}/dns-peering-zone-settings.yaml"
missingRolesDnsAdmin: ${GOOGLE_PROJECT_ID}
EOF
fi

cmd="gcloud projects get-iam-policy ${target_project} --flatten='bindings[].members' --format='table(bindings.role)' --filter='bindings.members:${dns_sa}' | grep roles/dns.peer"
run_command "${cmd}" || ret=1
if [ ${ret} -gt 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: The service account is lack of role 'roles/dns.peer' in project '${target_project}', temporarily grant it..."
  cmd="gcloud projects add-iam-policy-binding ${target_project} --member \"serviceAccount:${dns_sa}\" --role roles/dns.peer 1> /dev/null"
  backoff "${cmd}"

  cat <<EOF >>"${SHARED_DIR}/dns-peering-zone-settings.yaml"
missingRolesDnsPeer: ${target_project}
EOF
fi
