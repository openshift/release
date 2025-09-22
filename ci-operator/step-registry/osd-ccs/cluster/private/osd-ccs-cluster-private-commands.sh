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

function wait_for_dns() {
  local -r zone_name=$1; shift
  local -r expected_num_priv_ip=$1; shift
  local real_num_priv_ip
  local tmp_output
  local cmd
  local attempt=0
  local max_attempts=10

  tmp_output=$(mktemp)
  cmd="gcloud dns record-sets list --zone ${zone_name} --filter=\"(type=A OR type=SRV) AND NOT name~rh-api\" 2>/dev/null | tee ${tmp_output}"  
  while true; do
    logger "INFO" "Running Command '${cmd}'"
    eval "${cmd}"
    set +o errexit
    real_num_priv_ip=$(grep -P "\s+10\.[0-9\.]+$" "${tmp_output}" | wc -l)
    set -o errexit

    logger "INFO" "There are ${real_num_priv_ip} dns record-sets in zone '${zone_name}' with private IP addresses."
    if [[ ${real_num_priv_ip} -eq ${expected_num_priv_ip} ]]; then
      logger "INFO" "Found the expected ${real_num_priv_ip} dns record-sets in zone '${zone_name}' with private IP addresses."
      return 0
    fi

    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      break
    fi
    echo "Checking dns record-sets failed, retrying in $(( 2 ** attempt )) seconds"
    sleep $(( 2 ** attempt ))
  done

  logger "ERROR" "Expecting ${expected_num_priv_ip} dns record-sets in zone '${zone_name}' with private IP addresses, but found only ${real_num_priv_ip}."
  return 1
}

# Post installation check for private cluster
function check_private() {
  local api_lisening
  local priv_zone_name
  local priv_zone_dns
  local pub_zone_name
  local pub_zone_dns

  # 1. check API Listening
  api_lisening=$(ocm get cluster "${CLUSTER_ID}" | jq -r .api.listening)
  if [ "${api_lisening}" != "internal" ]; then
    logger "ERROR" "Cluster API Listening is '${api_lisening}' unexpectedly"
    return 1
  else
    logger "INFO" "check_private: Cluster API Listening is '${api_lisening}'"
  fi

  # 2. check on GCP the DNS record-sets
  ret=0
  gcloud_auth

  # find out the private DNS zone name and public DNS zone name
  priv_zone_name=$(gcloud dns managed-zones list --filter="name~${CLUSTER_NAME}" --format='value(name)')
  priv_zone_dns=$(gcloud dns managed-zones list --filter="name~${CLUSTER_NAME}" --format='value(dnsName)')
  pub_zone_dns="${priv_zone_dns#*.}"
  pub_zone_name=$(gcloud dns managed-zones list --filter="dnsName=${pub_zone_dns}" --format='value(name)')
  logger "INFO" "The DNS private zone: ${priv_zone_name} (${priv_zone_dns})"
  logger "INFO" "The DNS public zone: ${pub_zone_name} (${pub_zone_dns})"

  wait_for_dns "${pub_zone_name}" 2 || ret=$(( ret | 1 ))
  wait_for_dns "${priv_zone_name}" 3 || ret=$(( ret | 2 ))

  if [ $ret -eq 0 ]; then
    logger "INFO" "check_private: Cluster DNS record-sets check passed"
  else
    logger "INFO" "check_private: Cluster DNS record-sets check failed"
  fi
  return $ret
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
sleep 3600
check_private
