#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function logger() {
  local -r log_level=$1; shift
  local -r log_msg=$1; shift
  echo "$(date -u --rfc-3339=seconds) - ${log_level}: ${log_msg}"
}

# Authenticate to Google Cloud
function gcloud_auth() {
  local service_project_id

  if ! which gcloud; then
    GCLOUD_TAR="google-cloud-sdk-468.0.0-linux-x86_64.tar.gz"
    GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
    logger "INFO" "gcloud not installed, installing from $GCLOUD_URL"
    pushd ${HOME}
    curl -O "$GCLOUD_URL"
    tar -xzf "$GCLOUD_TAR"
    export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
    popd
  fi

  # login to the service project
  service_project_id="$(jq -r -c .project_id "${GCP_CREDENTIALS_FILE}")"
  gcloud auth activate-service-account --key-file="${GCP_CREDENTIALS_FILE}"
  gcloud config set project "${service_project_id}"
}

# Post installation check for private cluster
function check_private() {
  local api_lisening
  local priv_zone_name
  local priv_zone_dns
  local pub_zone_name
  local pub_zone_dns
  local tmp_output
  local cmd
  local num_priv_ip

  # 1. check API Listening
  api_lisening=$(ocm get cluster "${CLUSTER_ID}" | jq -r .api.listening)
  if [ "${api_lisening}" != "internal" ]; then
    logger "ERROR" "Cluster API Listening is '${api_lisening}' unexpectedly"
    return 1
  else
    logger "INFO" "check_private: Cluster API Listening is '${api_lisening}'"
  fi

  # 2. check on GCP the DNS record-sets
  tmp_output=$(mktemp)
  gcloud_auth

  # find out the private DNS zone name and public DNS zone name
  priv_zone_name=$(gcloud dns managed-zones list --filter="name~${CLUSTER_NAME}" --format='value(name)')
  priv_zone_dns=$(gcloud dns managed-zones list --filter="name~${CLUSTER_NAME}" --format='value(dnsName)')
  pub_zone_dns="${priv_zone_dns#*.}"
  pub_zone_name=$(gcloud dns managed-zones list --filter="dnsName=${pub_zone_dns}" --format='value(name)')
  logger "INFO" "The DNS private zone: ${priv_zone_name} (${priv_zone_dns})"
  logger "INFO" "The DNS public zone: ${pub_zone_name} (${pub_zone_dns})"

  # list DNS record-sets
  cmd="gcloud dns record-sets list --zone ${pub_zone_name} --filter=\"(type=A OR type=SRV) AND NOT name~rh-api\" 2>/dev/null | tee ${tmp_output}"
  logger "INFO" "Running Command '${cmd}'"
  eval "${cmd}"
  set +o errexit
  num_priv_ip=$(grep -P "\s+10\.[0-9\.]+$" "${tmp_output}" | wc -l)
  set -o errexit
  logger "INFO" "There are ${num_priv_ip} dns record-sets in public zone '${pub_zone_name}' with private IP addresses."
  # Expecting both api and *.apps dns record-sets in public zone are with private IP addresses
  if [ ${num_priv_ip} -lt 2 ]; then
    logger "ERROR" "One or more api/*.apps dns record-sets in zone '${pub_zone_name}' are with non-private IP address."
    return 1
  fi
  cmd="gcloud dns record-sets list --zone ${priv_zone_name} --filter=\"(type=A OR type=SRV) AND NOT name~rh-api\" 2>/dev/null | tee ${tmp_output}"
  logger "INFO" "Running Command '${cmd}'"
  eval "${cmd}"
  set +o errexit
  num_priv_ip=$(grep -P "\s+10\.[0-9\.]+$" "${tmp_output}" | wc -l)
  set -o errexit
  logger "INFO" "There are ${num_priv_ip} dns record-sets in zone '${priv_zone_name}' with private IP addresses."
  # Expecting all api, api-int and *.apps dns record-sets in private zone are with private IP addresses
  if [ ${num_priv_ip} -lt 3 ]; then
    logger "ERROR" "One or more api/api-int/*.apps dns record-sets in private zone '${priv_zone_name}' are with non-private IP address."
    return 1
  fi

  logger "INFO" "check_private: Cluster DNS record-sets check passed"
  return 0
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
logger "INFO" "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Required
GCP_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/osd-ccs-gcp.json"

if [ -z "${CLUSTER_NAME}" ]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
fi
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

check_private
