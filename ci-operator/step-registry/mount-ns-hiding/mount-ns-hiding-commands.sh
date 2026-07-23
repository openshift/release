#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LOGLEVEL=0

case $MOUNT_NS_HIDING_LOG in
  "0")
    LOGLEVEL=0
    ;;
  "1")
    LOGLEVEL=1
    ;;
  "2")
    LOGLEVEL=2
    ;;
  *)
    LOGLEVEL=0
    ;;
esac

function _log() {
  local level=$1; shift
  if [[ $level -le $LOGLEVEL ]]; then
    echo "$(date +%F) $(date +%T) $(date +%Z): $*" >&2
  fi
}

function log_err() {
  _log 0 "$*"
}

function log_info() {
  _log 1 "$*"
}

function log_debug() {
  _log 2 "$*"
}

function create_mount_namespace_hiding_mc(){
  # enabled can be either "true" or "false"
  local enabled="$1"

  local action="enable"
  if [ "$enabled" = "false" ]; then
    action="disable"
  fi

  local machineconfig=""

  for role in master worker
  do
    log_info "[INFO] Rendering machineconfig to $action mount namespace hiding for $role node(s)"

    str=$(cat << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $role
  name: 99-custom-enable-kubens-$role
spec:
  config:
    ignition:
      version: 2.2.0
    systemd:
      units:
      - enabled: $enabled
        name: kubens.service
---
EOF
)
    machineconfig+="${str}\n"
  done

  log_info "[INFO] Applying machineconfigs..."
  echo -en "$machineconfig" | oc apply -f -

  log_info "[INFO] Waiting for all machineconfigs to begin rolling out"
  oc wait --for=condition=Updating mcp --all --timeout=5m

  log_info "[INFO] Waiting for all machineconfigs to finish rolling out"
  oc wait --for=condition=Updated mcp --all --timeout=30m
  log_info "[INFO] Finished rolling out machineconfigs!"
}

function enable_mount_namespace_hiding(){
  create_mount_namespace_hiding_mc "true"
}

function disable_mount_namespace_hiding(){
  create_mount_namespace_hiding_mc "false"
}


log_debug "[DEBUG] Starting to run mount-ns-hiding-commands.sh script!"

if [ -z "${MOUNT_NS_HIDING_ENABLED}" ]; then
  log_error "[ERROR] MOUNT_NS_HIDING_ENABLED not defined!"
  exit 1
else
  log_debug "[DEBUG] MOUNT_NS_HIDING_ENABLED = ${MOUNT_NS_HIDING_ENABLED}"
fi

# Determine whether the cluster has the mount namespace hiding feature enabled
#  note: both master and worker nodes are checked!
enabled="true"

mc_list=$(oc get mc -o custom-columns='NAME:.metadata.name')
log_debug "[DEBUG] mc_list ="
log_debug "${mc_list}"

if [ ! -z "${mc_list}" ]; then
  for role in master worker
  do
    if [ "${enabled}" = "false" ]; then
      break
    fi

    str="kubens-$role"

    log_debug "[DEBUG] About to grep for $str"

    if grep -q "$str" <<< "$mc_list"; then
      mc_name=$(grep "$str" <<< "$mc_list")
      log_debug "[DEBUG] mc_name = ${mc_name}"

      if [ -z "${mc_name}" ]; then
        # if no mnt-ns-hiding machineconfig found - set enabled to false
        log_info "[INFO] No mount namespace hiding machineconfig found!"
        enabled="false"
      else
        log_info "[INFO] Found the following machineconfig: ${mc_name}"
        is_enabled=$(oc get mc ${mc_name} -o jsonpath="{..systemd.units[?(@.name=='kubens.service')].enabled}")
        log_debug "[DEBUG] machineconfig: ${mc_name}, enabled=[${is_enabled}]"
        if [ "${is_enabled}" != "true" ]; then
          enabled="false"
        fi
      fi
    else
      log_info "[INFO] Unable to find $str in the machineconfigs retrieved!"
      enabled="false"
    fi
  done
else
  log_info "[INFO] Unable to retrieve machineconfigs!"
  enabled="false"
fi

log_debug "[DEBUG] mount namespace hiding feature has enabled=[${enabled}]"

# Only enable mnt-ns-hiding feature if $MOUNT_NS_HIDING_ENABLED=true
#  and the feature is currently disabled (i.e. $enabled=false)
# Only disable mnt-ns-hiding feature if $MOUNT_NS_HIDING_ENABLED=false
#  and the feature is currently enabled (i.e. $enabled=true)

if [ "${MOUNT_NS_HIDING_ENABLED}" = "true" ] && [ "${enabled}" = "false" ]; then
  log_info "[INFO] Enabling the mount ns hiding feature!"
  enable_mount_namespace_hiding
elif [ "${MOUNT_NS_HIDING_ENABLED}" = "false" ] && [ "${enabled}" = "true" ]; then
  log_info "[INFO] Disabling the mount ns hiding feature!"
  disable_mount_namespace_hiding
else
  log_info "[INFO] Neither enabling nor disabling the mount ns hiding feature!"
fi


