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

HOLD_TIME_BEFORE_UPGRADE=${HOLD_TIME_BEFORE_UPGRADE:-"0"}
CP_UPGRADE_TIMEOUT=${CP_UPGRADE_TIMEOUT:-"14400"}

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
  available_versions=$(rosa list upgrade -c $cluster_id -ojson)
  available_version=""
  if [[ "$available_versions" != *"There are no available upgrades"* ]]; then
    current_prefix=$(echo "$current_version" | awk -F. '{print $1"."$2}')
    if [[ -n $available_versions ]]; then
      clean_data=$(echo "$available_versions" | sed 's/[][",]//g')
      readarray -t versionsList <<< "$(echo "$clean_data" | sed '/^[[:space:]]*$/d' | awk '{$1=$1;print}')"
      readarray -t sorted_versions < <(printf "%s\n" "${versionsList[@]}" | sort -rV)
      log "Available upgrade versions: ${sorted_versions[*]}"

      if [[ "$Z_STREAM_UPGRADE" == "true" ]]; then
        for ver in "${sorted_versions[@]}"; do
          if [[ "$ver" =~ ^${current_prefix}\. ]]; then
            available_version=$ver
            log "Z Stream Upgrade version: ($available_version)"
            break
          fi
        done
      else
        target_prefix=${UPGRADED_TO_VERSION:-}
        if [[ -n "$target_prefix" ]]; then
          for ver in "${sorted_versions[@]}"; do
            if [[ "$ver" =~ ^${target_prefix}\. ]]; then
              available_version=$ver
              log "Y Stream Upgrade version: ($available_version)"
              break
            fi
          done
        else
          for ver in "${sorted_versions[@]}"; do
            if [[ ! "$ver" =~ ^${current_prefix}\. ]]; then
              available_version=$ver
              log "Y Stream Upgrade version: ($available_version)"
              break
            fi
          done
        fi
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

init_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')

UPGRADE_CHANNEL=${UPGRADE_CHANNEL:-}
if [[ -n "${UPGRADE_CHANNEL}" ]]; then
  log "Changing cluster channel to ${UPGRADE_CHANNEL}"
  rosa edit cluster -c $cluster_id --channel "${UPGRADE_CHANNEL}"
  sleep 60
fi

upgraded_to_version=$init_version
get_cluster_upgrade_path

if [ -n "$available_version" ]; then
  upgrade_cluster_to $available_version
  upgraded_to_version=$available_version
  log "Upgrade control plane from $init_version to $upgraded_to_version"
else
  log "No available version for upgrade from $init_version"
fi

echo "$upgraded_to_version" > "${SHARED_DIR}/upgraded_to_version"
log "Control plane upgraded to $upgraded_to_version"
 
