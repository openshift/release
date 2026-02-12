#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
	local CMD="$1"
	echo "Running Command: ${CMD}" >&2
	eval "${CMD}"
}

if [[ -s "${SHARED_DIR}/xpn.json" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/xpn_creds.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Activating XPN service-account..."
  GOOGLE_CLOUD_XPN_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/xpn_creds.json"
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_XPN_KEYFILE_JSON}"
  GOOGLE_CLOUD_XPN_SA=$(jq -r .client_email "${GOOGLE_CLOUD_XPN_KEYFILE_JSON}")
fi
if [[ "${OSD_QE_PROJECT_AS_SERVICE_PROJECT}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Activating OSD QE service account & project..."
  export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/osd-ccs-gcp.json"
  GOOGLE_PROJECT_ID="$(jq -r -c .project_id "${GCP_SHARED_CREDENTIALS_FILE}")"
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
else
  GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
  export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
  sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
  if ! gcloud auth list | grep -E "\*\s+${sa_email}"
  then
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${GOOGLE_PROJECT_ID}"
  fi
fi

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"

## Destroying DNS resources of the mirror registry
mirror_registry_priv_zone_name="${CLUSTER_NAME}-mirror-registry-private-zone"
mirror_registry_priv_zone_info=$(gcloud dns managed-zones list --filter="name=${mirror_registry_priv_zone_name}")
if [ -n "${mirror_registry_priv_zone_info}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Deleting the record-sets and then the private zone of mirror registry..."
  readarray -t recordsets < <(gcloud dns record-sets list --zone="${mirror_registry_priv_zone_name}" --filter='type=A' --format='value(name)')
  if [ ${#recordsets[@]} -gt 0 ]; then
    for rs in "${recordsets[@]}"; do
      cmd="gcloud dns record-sets delete -q ${rs} --type=A --zone=${mirror_registry_priv_zone_name}"
      run_command "${cmd}"
    done
  fi
  cmd="gcloud dns managed-zones delete -q ${mirror_registry_priv_zone_name}"
  run_command "${cmd}"
else
  echo "$(date -u --rfc-3339=seconds) - The mirror registry private zone '${mirror_registry_priv_zone_name}' doesn't exist."
fi
mirror_registry_rs_in_base_domain=$(gcloud dns record-sets list --zone="${BASE_DOMAIN_ZONE_NAME}" --filter="name~${CLUSTER_NAME}.mirror-registry")
if [ -n "${mirror_registry_rs_in_base_domain}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Deleting the record-sets of mirror registry in base domain..."
  cmd="gcloud dns record-sets delete -q ${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}. --type=A --zone=${BASE_DOMAIN_ZONE_NAME}"
  run_command "${cmd}"
else
  echo "$(date -u --rfc-3339=seconds) - The record-sets of the mirror registry in base domain doesn't exist."
fi

## Destroy the bastion host
ZONE_0=$(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9)
bastion_name="${CLUSTER_NAME}-bastion"

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  project_option="--project=${HOST_PROJECT} --account ${GOOGLE_CLOUD_XPN_SA}"
else
  project_option=""
fi

bastion_info=$(gcloud compute instances list --filter="name=${bastion_name}")
if [ -n "${bastion_info}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Deleting the bastion host..."
  cmd="gcloud compute instances delete -q ${bastion_name} --zone=${ZONE_0}"
  run_command "${cmd}"
else
  echo "$(date -u --rfc-3339=seconds) - The bastion host doesn't exist."
fi

cmd="gcloud ${project_option} compute firewall-rules list --filter='name=${bastion_name}-ingress-allow'"
run_command "${cmd}"

bastion_firewall_rule_info=$(gcloud ${project_option} compute firewall-rules list --filter="name=${bastion_name}-ingress-allow")
if [ -n "${bastion_firewall_rule_info}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Deleting the firewall-rule of the bastion host..."
  cmd="gcloud ${project_option} compute firewall-rules delete -q ${bastion_name}-ingress-allow"
  run_command "${cmd}"
else
  echo "$(date -u --rfc-3339=seconds) - The firewall-rule of the bastion host doesn't exist."
fi
