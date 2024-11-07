#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

cluster_id=$(head -n 1 "${SHARED_DIR}/cluster-id")
HOSTED_CP=${HOSTED_CP:-false}
UPGRADED_TO_VERSION=${UPGRADED_TO_VERSION:-}
CLUTER_UPGRADE_TIMEOUT=${CLUTER_UPGRADE_TIMEOUT:-"14400"}
NODE_UPGRADE_TIMEOUT=${NODE_UPGRADE_TIMEOUT:-"7200"}

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
        # cat "${SHARED_DIR}/proxy-conf.sh"
        log "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        log "no proxy setting."
    fi
}

function unset_proxy () {
    if test -s "${SHARED_DIR}/unset-proxy.sh" ; then
        log "unset the proxy"
        log "source ${SHARED_DIR}/unset-proxy.sh"
        source "${SHARED_DIR}/unset-proxy.sh"
    else
        log "no proxy setting found."
    fi
}

function get_recommended_version_for_cluster () {
  major_version=$1
  recommended_version=$(rosa list upgrade -c $cluster_id | grep -v 'no available upgrades' | grep 'recommended' | grep $major_version | cut -d ' ' -f1 || true)
  if [[ -z "$recommended_version" ]]; then
    log "Error: No recommended $major_version version for the cluster $cluster_id to be upgraded to."
    exit 1
  fi
}

function get_recommended_version_for_machinepool () {
  mp_id=$1
  major_version=$2
  mp_recommended_version=$(rosa list upgrade --machinepool $mp_id -c $cluster_id | grep -v 'no available upgrades' | grep 'recommended' | grep $major_version | cut -d ' ' -f1 || true)
  if [[ -z "$mp_recommended_version" ]]; then
    log "Error: No recommended $major_version version for the machinepool $mp_id to be upgraded to."
    exit 1
  fi
}

function upgrade_cluster_to () {
  major_version=$1
  recommended_version=""
  get_recommended_version_for_cluster $major_version

  # Create upgrade scedule
  log "Upgrade the cluster $cluster_id to $recommended_version"
  echo "rosa upgrade cluster -y -m auto --version $recommended_version -c $cluster_id ${HCP_SWITCH}"
  start_time=$(date +"%s")
  while true; do
    if (( $(date +"%s") - $start_time >= 1800 )); then
      log "error: Timed out while waiting for the previous upgrade schedule to be removed."
      exit 1
    fi

    rosa upgrade cluster -y -m auto --version $recommended_version -c $cluster_id ${HCP_SWITCH} 1>"/tmp/update_info.txt" 2>&1 || true
    upgrade_info=$(cat "/tmp/update_info.txt")
    if [[ "$upgrade_info" == *"There is already"* ]]; then
      log "Waiting for the previous upgrade schedule to be removed."
      sleep 120
    else
      log -e "$upgrade_info"
      break
    fi
  done

  # Speed up the upgrading process
  set_proxy
  if [[ "$HOSTED_CP" == "false" ]]; then
    log "Force restarting the MUO pod to speed up the upgrading process."
    muo_pod=$(oc get pod -n openshift-managed-upgrade-operator | grep 'managed-upgrade-operator' | grep -v 'catalog' | cut -d ' ' -f1)
    oc delete pod $muo_pod -n openshift-managed-upgrade-operator
  fi
  unset_proxy

  # Upgrade cluster
  start_time=$(date +"%s")
  while true; do
    sleep 120
    log "Wait for the cluster upgrading finished ..."
    current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
    if [[ "$current_version" == "$recommended_version" ]]; then
      record_cluster "timers.ocp_upgrade" "${recommended_version}" $(( $(date +"%s") - "${start_time}" ))
      log "Upgrade the cluster $cluster_id to the openshift version $recommended_version successfully after $(( $(date +"%s") - ${start_time} )) seconds"
      break
    fi

    # for ROSA HCP, when control plane is upgrading, worker nodes should not be recreated
    if [[ "$HOSTED_CP" == "true" ]]; then
      set_proxy
      check_worker_node_not_changed
      unset_proxy
    fi

    if (( $(date +"%s") - $start_time >= $CLUTER_UPGRADE_TIMEOUT )); then
      log "error: Timed out while waiting for the cluster upgrading to be ready"
      set_proxy
      oc get clusteroperators
      exit 1
    fi
  done

  if [[ "$HOSTED_CP" == "true" ]]; then
    echo "rosa hcp control plane upgrade done, check worker nodes status again"
    set_proxy
    check_worker_node_not_changed
    unset_proxy
  fi
}

function upgrade_machinepool_to () {
  rosa list machinepool -c $cluster_id

  major_version=$1
  mp_id_list=$(rosa list machinepool -c $cluster_id -o json | jq -r ".[].id")
  for mp_id in $mp_id_list; do
    mp_recommended_version=""
    get_recommended_version_for_machinepool $mp_id $major_version
    log "Upgrade the machinepool $mp_id to $mp_recommended_version"
    log "rosa upgrade machinepool $mp_id -y -c $cluster_id --version $mp_recommended_version"
    rosa upgrade machinepool $mp_id -y -c $cluster_id --version $mp_recommended_version
  done

  for mp_id in $mp_id_list; do
    start_time=$(date +"%s")
    while true; do
        sleep 120
        log "Wait for the node upgrading for the machinepool $mp_id finished ..."
        node_version=$(rosa list machinepool -c $cluster_id -o json | jq -r --arg k $mp_id '.[] | select(.id==$k) .version.id')
        if [[ "$node_version" =~ ${mp_recommended_version}- ]]; then
          record_cluster "timers.machinset_upgrade" "${mp_id}" $(( $(date +"%s") - "${start_time}" ))
          log "Upgrade the machinepool $mp_id successfully to the openshift version $mp_recommended_version after $(( $(date +"%s") - ${start_time} )) seconds"
          break
        fi

        if (( $(date +"%s") - $start_time >= $NODE_UPGRADE_TIMEOUT )); then
          log "error: Timed out while waiting for the machinepool upgrading to be ready"
          rosa list machinepool -c $cluster_id
          exit 1
        fi
    done
  done
}

# check if the nodes are Ready status
function check_node() {
    local node_number ready_number
    node_number=$(oc get node --no-headers | grep -cv STATUS)
    ready_number=$(oc get node --no-headers | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status Ready"
        return 0
    else
        echo "Find Not Ready worker nodes, node recreated"
        oc get no
        exit 1
    fi
}

function check_worker_node_not_changed() {
  check_node
  # ensure the worker node UIDs are not changed
  current_uids=$(oc get nodes -o jsonpath='{.items[*].metadata.uid}')
  IFS=' ' read -r -a current_array <<< "$current_uids"
  sorted_current_uids=$(printf "%s\n" "${current_array[@]}" | sort | tr '\n' ' ')

  # compare the worker nodes UIDs
  if [ "$sorted_initial_uids" == "$sorted_current_uids" ]; then
      echo "No changes detected in node UIDs. $sorted_current_uids"
  else
      echo "Node UIDs have changed!"
      echo "Initial UIDs: $sorted_initial_uids"
      echo "Current UIDs: $sorted_current_uids"
      exit 1
  fi
}

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  log "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

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

HCP_SWITCH=""
if [[ "$HOSTED_CP" == "true" ]]; then
  HCP_SWITCH="--control-plane"
fi

if [[ -z "${UPGRADED_TO_VERSION}" ]]; then
  log "The UPGRADED_TO_VERSION is mandatory!"
  exit 1
fi
current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
if [[ "$current_version" == "$UPGRADED_TO_VERSION" ]]; then
  log "The cluster has been in the version $UPGRADED_TO_VERSION"
  exit 1
fi

# initial worker nodes uids
initial_uids=""
sorted_initial_uids=""
if [[ "$HOSTED_CP" == "true" ]]; then
  set_proxy
  initial_uids=$(oc get nodes -o jsonpath='{.items[*].metadata.uid}')
  IFS=' ' read -r -a initial_array <<< "$initial_uids"
  sorted_initial_uids=$(printf "%s\n" "${initial_array[@]}" | sort | tr '\n' ' ')
  echo "initial worker node uids: $sorted_initial_uids"
  oc get no -owide
  unset_proxy
fi

end_version_x=$(echo ${UPGRADED_TO_VERSION} | cut -d '.' -f1)
end_version_y=$(echo ${UPGRADED_TO_VERSION} | cut -d '.' -f2)
current_version_x=$(echo $current_version | cut -d '.' -f1)
current_version_y=$(echo $current_version | cut -d '.' -f2)
start_version_x=$current_version_x
start_version_y=$current_version_y
if [[ "$end_version_x" == "$current_version_x" ]]; then
  start_version_y=$current_version_y
  if [[ $end_version_y -gt $start_version_y ]]; then
    start_version_y=$(expr $start_version_y + 1)
  fi

  for y in $(seq $start_version_y $end_version_y); do
    upgrade_cluster_to "$start_version_x.$y"
    if [[ "$HOSTED_CP" == "true" && "$HCP_NODE_UPGRADE_ENABLED" == "true" ]]; then
      upgrade_machinepool_to "$start_version_x.$y"
    fi
  done
else
  # For X-Stream upgrade, only support X+1
  upgrade_cluster_to $UPGRADED_TO_VERSION
  if [[ "$HOSTED_CP" == "true" && "$HCP_NODE_UPGRADE_ENABLED" == "true" ]]; then
    upgrade_machinepool_to "$start_version_x.$y"
  fi
fi
