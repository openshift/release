#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function release_locked_host {

  local network_spoke_mac_address
  network_spoke_mac_address=$(cat $SHARED_DIR/hosts.yaml|grep 'mac:'|awk -F'mac:' '{print $2}'|tr -d '[:blank:]')
  local spoke_lock_filename="/var/run/lock/ztp-baremetal-pool/spoke-baremetal-${network_spoke_mac_address//:/-}.lock"

  echo "************ telcov10n Releasing Lock for the host used by this Spoke cluster deployment ************"

  set -x
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
    "sudo rm -fv ${spoke_lock_filename} && echo 'Lock released successfully.'"
  set +x
}

function server_poweroff {

  echo "************ telcov10n Power Off the server use as SNO Spoke cluster ************"

  post_curl_=$(sed "s@curl@curl -X POST -d '{\"ResetType\": \"ForceOff\"}'@" ${SHARED_DIR}/curl_redfish_base_uri)
  echo
  echo "Shutting down the server..."
  eval "${post_curl_}/Actions/ComputerSystem.Reset"
  echo

  curl_="$(cat ${SHARED_DIR}/curl_redfish_base_uri)"
  ${curl_} | jq -r '.PowerState'
  echo
  echo "Waiting for the server gets shutdown..."
  # shellcheck disable=SC2034
  show_command="no"
  wait_until_command_is_ok "${curl_} | jq -r '.PowerState' | grep -w 'Off'" 10s 100

}

function cleanup_waiting_file {
  # Always clean up our waiting file, regardless of lock status

  if [ ! -f "${SHARED_DIR}/own_waiting_file.txt" ]; then
    echo "[INFO] No waiting file to clean up."
    return 0
  fi

  local own_waiting_file
  own_waiting_file=$(cat "${SHARED_DIR}/own_waiting_file.txt")

  if [ -z "${own_waiting_file}" ]; then
    echo "[INFO] Waiting file path is empty, nothing to clean up."
    return 0
  fi

  echo "************ telcov10n Cleaning up waiting file ************"
  echo "[INFO] Removing waiting file: ${own_waiting_file}"

  timeout -s 9 2m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
    "rm -fv ${own_waiting_file} 2>/dev/null || true"
}

function main {

  # Setup SSH access once for all operations
  setup_aux_host_ssh_access

  # Always clean up our waiting file first (handles both timeout and normal cases)
  cleanup_waiting_file

  # Only do lock-related cleanup if we hold the lock
  local does_the_current_job_hold_a_lock_to_use_a_baremetal_server
  does_the_current_job_hold_a_lock_to_use_a_baremetal_server=$( \
    cat ${SHARED_DIR}/do_you_hold_the_lock_for_the_sno_spoke_cluster_server.txt || echo "no")

  if [ "${does_the_current_job_hold_a_lock_to_use_a_baremetal_server}" == "yes" ]; then
    server_poweroff
    # This must be run the latest one since it releases its server lock
    release_locked_host
  fi
}

main
