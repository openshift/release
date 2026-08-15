#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"

cluster_id=$(cat "${SHARED_DIR}/cluster-id")

NP_UPGRADE_TIMEOUT=${NP_UPGRADE_TIMEOUT:-"7200"}

cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  log "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

HOSTED_CP=$(rosa describe cluster -c $cluster_id -o json | jq -r '.hypershift.enabled')
if [[ "$HOSTED_CP" != "true" ]]; then
  log "error: This step is only for ROSA HCP clusters, but the cluster $cluster_id is not HCP."
  exit 1
fi

if [[ -f "${SHARED_DIR}/upgraded_to_version" ]]; then
  UPGRADED_TO_VERSION=$(cat "${SHARED_DIR}/upgraded_to_version")
else
  UPGRADED_TO_VERSION=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
fi
log "Upgrading machinepools to version: $UPGRADED_TO_VERSION"

log "rosa list machinepool -c $cluster_id"
rosa list machinepool -c $cluster_id

mp_id_list=$(rosa list machinepool -c $cluster_id -o json | jq -r ".[].id")
declare -A machinepool_start_times
for mp_id in $mp_id_list; do
  machinepool_start_times["$mp_id"]=$(date +"%s")
  log "rosa upgrade machinepool $mp_id -y -c $cluster_id --version $UPGRADED_TO_VERSION"
  rosa upgrade machinepool $mp_id -y -c $cluster_id --version $UPGRADED_TO_VERSION
done

for mp_id in $mp_id_list; do
  start_time=${machinepool_start_times["$mp_id"]}
  while true; do
      sleep 120
      log "Wait for the node upgrading for the machinepool $mp_id finished ..."
      node_version=$(rosa list machinepool -c $cluster_id -o json | jq -r --arg k $mp_id '.[] | select(.id==$k) .version.id')
      if [[ "$node_version" =~ ${UPGRADED_TO_VERSION}- ]]; then
        record_cluster "timers.machinset_upgrade" "${mp_id}" $(( $(date +"%s") - "${start_time}" ))
        log "Upgrade the machinepool $mp_id successfully to the openshift version $UPGRADED_TO_VERSION after $(( $(date +"%s") - ${start_time} )) seconds"
        break
      fi

      if (( $(date +"%s") - $start_time >= $NP_UPGRADE_TIMEOUT )); then
        log "error: Timed out while waiting for the machinepool upgrading to be ready"
        rosa list machinepool -c $cluster_id
        exit 1
      fi
  done
done
