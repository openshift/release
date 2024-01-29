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

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function unset_proxy () {
    if test -s "${SHARED_DIR}/unset-proxy.sh" ; then
        echo "unset the proxy"
        echo "source ${SHARED_DIR}/unset-proxy.sh"
        source "${SHARED_DIR}/unset-proxy.sh"
    else
        echo "no proxy setting found."
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

    rosa upgrade cluster -y -m auto --version $recommended_version -c $cluster_id ${HCP_SWITCH} 1>"/tmp/update_info.txt" 2>&1
    upgrade_info=$(cat "/tmp/update_info.txt")
    if [[ "$upgrade_info" == *"There is already"* ]]; then
      echo "Waiting for the previous upgrade schedule to be removed."
      sleep 120
    else
      echo -e "$upgrade_info"
      break
    fi
  done

  # Speed up the upgrading process
  set_proxy
  echo "Force restarting the MUO pod to speed up the upgrading process."
  muo_pod=$(oc get pod -n openshift-managed-upgrade-operator | grep 'managed-upgrade-operator' | grep -v 'catalog' | cut -d ' ' -f1)
  oc delete pod $muo_pod -n openshift-managed-upgrade-operator
  unset_proxy

  # Upgrade cluster
  start_time=$(date +"%s")
  while true; do
    sleep 120
    echo "Wait for the cluster upgrading finished ..."
    current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
    if [[ "$current_version" == "$recommended_version" ]]; then
      log "Upgrade the cluster $cluster_id to the openshift version $recommended_version successfully"
      break
    fi

    if (( $(date +"%s") - $start_time >= $CLUTER_UPGRADE_TIMEOUT )); then
      log "error: Timed out while waiting for the cluster upgrading to be ready"
      set_proxy
      oc get clusteroperators
      exit 1
    fi
  done
}

function upgrade_machinepool_to () {
  rosa list machinepool -c $cluster_id

  major_version=$1
  mp_id_list=$(rosa list machinepool -c $cluster_id -o json | jq -r ".[].id")
  for mp_id in $mp_id_list; do
    mp_recommended_version=""
    get_recommended_version_for_machinepool $mp_id $major_version
    log "Upgrade the machinepool $mp_id to $mp_recommended_version"
    echo "rosa upgrade machinepool $mp_id -y -c $cluster_id --version $mp_recommended_version"
    rosa upgrade machinepool $mp_id -y -c $cluster_id --version $mp_recommended_version
  done

  for mp_id in $mp_id_list; do
    start_time=$(date +"%s")
    while true; do
        sleep 120
        echo "Wait for the node upgrading for the machinepool $mp_id finished ..."
        node_version=$(rosa list machinepool -c $cluster_id -o json | jq -r --arg k $mp_id '.[] | select(.id==$k) .version.id')
        if [[ "$node_version" =~ ${mp_recommended_version}- ]]; then
          log "Upgrade the machinepool $mp_id to the openshift version $mp_recommended_version successfully"
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

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

HCP_SWITCH=""
if [[ "$HOSTED_CP" == "true" ]]; then
  HCP_SWITCH="--control-plane"
fi

if [[ -z "${UPGRADED_TO_VERSION}" ]]; then
  echo "The UPGRADED_TO_VERSION is mandatory!"
  exit 1
fi
current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
if [[ "$current_version" == "$UPGRADED_TO_VERSION" ]]; then
  echo "The cluster has been in the version $UPGRADED_TO_VERSION"
  exit 1
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
    if [[ "$HOSTED_CP" == "true" ]]; then
      upgrade_machinepool_to "$start_version_x.$y"
    fi
  done
else
  # For X-Stream upgrade, only support X+1
  upgrade_cluster_to $UPGRADED_TO_VERSION
  if [[ "$HOSTED_CP" == "true" ]]; then
    upgrade_machinepool_to "$start_version_x.$y"
  fi
fi
