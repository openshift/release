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

  echo "************ telcov10n Releasing Lock for the host used by this Spoke cluster deployemnt ************"

  set -x
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s --  \
    "${spoke_lock_filename}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail
sudo rm -fv ${1}
EOF
  set +x
}

function hack_spoke_deployment_clean_up {

  echo "************ telcov10n hack spoke deployment clean up ************"

  release_locked_host
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

function main {

  setup_aux_host_ssh_access
  hack_spoke_deployment_clean_up
  server_poweroff
}

main
