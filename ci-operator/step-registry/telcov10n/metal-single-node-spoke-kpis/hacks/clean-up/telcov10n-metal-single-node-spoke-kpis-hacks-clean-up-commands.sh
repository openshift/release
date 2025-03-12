#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function setup_aux_host_ssh_access {

  echo "************ telcov10n Setup AUX_HOST SSH access ************"

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  )

}

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

function main {

  setup_aux_host_ssh_access
  hack_spoke_deployment_clean_up
}

main
