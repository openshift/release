#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}


source ./tests/prow_ci.sh

# functions are defined in https://github.com/openshift/rosa/blob/master/tests/prow_ci.sh
#configure aws
aws_region=${REGION:-us-east-2}
configure_aws "${CLUSTER_PROFILE_DIR}/.awscred" "${aws_region}"
configure_aws_shared_vpc ${CLUSTER_PROFILE_DIR}/.awscred_shared_account
cluster_id=$(cat "${SHARED_DIR}/cluster-id")

HOLD_TIME_BEFORE_UPGRADE=${HOLD_TIME_BEFORE_UPGRADE:-"0"}
CP_UPGRADE_TIMEOUT=${CP_UPGRADE_TIMEOUT:-"14400"}
NP_UPGRADE_TIMEOUT=${NP_UPGRADE_TIMEOUT:-"7200"}
test_timeout=`expr $CP_UPGRADE_TIMEOUT + $NP_UPGRADE_TIMEOUT`

# Record Cluster Configurations
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

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        log "setting the proxy"
        log "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        log "no proxy setting."
    fi
}

function get_cluster_upgrade_path () {
  current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
  available_versions=$(rosa list upgrade -c $cluster_id  -ojson)
  available_version=""
  if [[ "$available_versions" != *"There are no available upgrades"* ]]; then
    prefix=$(echo "$current_version" | awk -F. '{print $1"."$2}')
    if [[ -n $available_versions ]];then
      clean_data=$(echo "$available_versions" | sed 's/[][",]//g')
      readarray -t versionsList <<< "$(echo "$clean_data" | sed '/^[[:space:]]*$/d' | awk '{$1=$1;print}')"
      readarray -t sorted_versions < <(printf "%s\n" "${versionsList[@]}" | sort -V)
      log "Get the available upgrade versions:\n" "${sorted_versions[@]}"
      # Find the Y stream upgrade version firstly
      for ver in "${sorted_versions[@]}"; do
        if [[ ! "$ver" =~ $prefix ]]; then
          available_version=$ver
          log "Y Stream Upgrade version: ($available_version)"
          break
        fi
      done
      # Find the Z stream upgrade version secondly
      if [[ -z $available_version ]];then
        for ver in "${versionsList[@]}"; do
         if [[ "$ver" =~ "$prefix"* ]]; then
           available_version="$ver"
           log "Z Stream Upgrade path: (${available_version})"
           break
         fi
        done 
      fi
    fi
  fi 
}


function upgrade_cluster_to () {
  available_version=$1
  start_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
  log "Upgrade the cluster $cluster_id to $available_version"
  echo "rosa upgrade cluster -y -m auto --version $available_version -c $cluster_id" 
  start_time=$(date +"%s")
  while true; do
    if (( $(date +"%s") - $start_time >= 1800 )); then
      log "error: Timed out while waiting for the previous upgrade schedule to be removed."
      exit 1
    fi

    rosa upgrade cluster -y -m auto --version $available_version -c $cluster_id  1>"/tmp/update_info.txt" 2>&1 || true
    upgrade_info=$(cat "/tmp/update_info.txt")
    if [[ "$upgrade_info" == *"There is already"* ]]; then
      log "Waiting for the previous upgrade schedule to be removed."
      sleep 120
    else
      log -e "$upgrade_info"
      break
    fi
  done

  # Monitor cluster
  start_time=$(date +"%s")
  while true; do
    sleep 120
    log "Wait for the cluster upgrading finished ..."
    current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
    if [[ "$current_version" == "$available_version" ]]; then
      record_cluster "timers.ocp_upgrade" "${available_version}" $(( $(date +"%s") - "${start_time}" ))
      log "Upgrade the cluster $cluster_id from $start_version to the openshift version $available_version successfully after $(( $(date +"%s") - ${start_time} )) seconds"
      break
    fi

    if (( $(date +"%s") - $start_time >= $CP_UPGRADE_TIMEOUT )); then
      log "error: Timed out while waiting for the cluster upgrading to be ready"
      set_proxy
      oc get clusteroperators
      exit 1
    fi
  done

}

function upgrade_machinepool_to () {
  log "rosa list machinepool -c $cluster_id"
  rosa list machinepool -c $cluster_id

  up_version=$1
  mp_id_list=$(rosa list machinepool -c $cluster_id -o json | jq -r ".[].id")
  for mp_id in $mp_id_list; do
    node_start_version=$(rosa list machinepool -c $cluster_id -o json | jq -r --arg k $mp_id '.[] | select(.id==$k) .version.id')
    log "rosa upgrade machinepool $mp_id -y -c $cluster_id --version $up_version"
    rosa upgrade machinepool $mp_id -y -c $cluster_id --version $up_version
  done

  for mp_id in $mp_id_list; do
    start_time=$(date +"%s")
    while true; do
        sleep 120
        log "Wait for the node upgrading for the machinepool $mp_id finished ..."
        node_version=$(rosa list machinepool -c $cluster_id -o json | jq -r --arg k $mp_id '.[] | select(.id==$k) .version.id')
        if [[ "$node_version" =~ ${up_version}- ]]; then
          record_cluster "timers.machinset_upgrade" "${mp_id}" $(( $(date +"%s") - "${start_time}" ))
          log "Upgrade the machinepool $mp_id successfully from $node_start_version to the openshift version $up_version after $(( $(date +"%s") - ${start_time} )) seconds"
          break
        fi

        if (( $(date +"%s") - $start_time >= $NP_UPGRADE_TIMEOUT )); then
          log "error: Timed out while waiting for the machinepool upgrading to be ready"
          rosa list machinepool -c $cluster_id
          exit 1
        fi
    done
  done
}


read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# hold on before upgrading cluster
start_time=$(date +"%s")
echo "$(date): Beginning to wait: ${HOLD_TIME_BEFORE_UPGRADE} seconds"
while true; do
  current_time=$(date +"%s")
  if (( "${current_time}" - "${start_time}" < "${HOLD_TIME_BEFORE_UPGRADE}" )); then
    sleep 60
    echo "Hold on before upgrading cluster: $(date)"
  else
    break
  fi
done

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  log "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

if [[ -z "$CHANNEL_GROUP" ]];then
  CHANNEL_GROUP=$(rosa describe cluster -c $cluster_id -o json | jq -r '.version.channel_group')
fi


log "Get the latest version!"
if [[ "$CHANNEL_GROUP" == "nightly" ]]; then
  log "It doesn't support to upgrade with nightly version now"
  exit 1
fi

HOSTED_CP=$(rosa describe cluster -c $cluster_id -o json | jq -r '.hypershift.enabled')
init_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')

start_time=$(date +"%s")
while true; do
  current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version') 
  # Get cluster upgrade version path : available_version
  get_cluster_upgrade_path

  # Get specified target version when UPGRADE_ENABLED is set true and compare with avaiable path version
  # Upgrade cluster to specidied target version
  if [[ "$UPGRADE_ENABLED" == "true" && -n "$UPGRADED_TO_VERSION" ]];then
    target_x=$(echo "$UPGRADED_TO_VERSION" | cut -d'.' -f1)
    target_y=$(echo "$UPGRADED_TO_VERSION" | cut -d'.' -f2)

    available_x=$(echo "$available_version" | cut -d'.' -f1)
    available_y=$(echo "$available_version" | cut -d'.' -f2)
    is_greater=0
    if (( available_x > target_x )); then
      is_greater=1
    elif (( target_x == available_x )) && (( available_y > target_y )); then
      is_greater=1
    fi

    if (( is_greater == 1 )); then
      log "Upgrade failed: target version $UPGRADED_TO_VERSION is below the minimum supported version $available_version."
      break
    fi
  fi
  
  
  # Upgrade cluster when there is upgrade path,otherwise return log 
  if [ -n "$available_version" ]; then
    upgrade_cluster_to $available_version
    if [ "$HOSTED_CP" = "true" ]; then
      upgrade_machinepool_to $available_version
    fi
    log "Upgrade cluster and machine pool from init version $init_version to final version $current_version"
  else
    log "No available version for upgrade $current_version"
    break
  fi
  

  # Record log when timeout
  current_time=$(date +"%s")
  if (( "${current_time}" - "${start_time}" >= "${test_timeout}" )); then
    log "error: Timed out while waiting for upgrading cluster"
    record_cluster "timers" "cluster current version" "${current_version}"
    exit 1
  fi
done
 
