#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function update_selected_vhub_to_use {

  echo "************ telcov10n Update the selected virtualised SNO Hub cluster as installed ************"

  local virtualized_hub_pool_fname
  virtualized_hub_pool_fname=${1} ; shift
  local hub_id
  hub_id=${1} ; shift

  echo
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "'${hub_id}'" "${virtualized_hub_pool_fname}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

set -x
hub_id=${1}
virtualized_hub_pool_fname=${2}

hub_pool=$(cat ${virtualized_hub_pool_fname} | jq -c)
hub_pool=$(jq -c --arg id "${hub_id}" '
  (.pool[] | select(.hub_id == $id))
  |= (.state = "installed")
  ' <<<"${hub_pool}")

echo ${hub_pool} >| ${virtualized_hub_pool_fname}
set +x

echo "---------------------"
cat ${virtualized_hub_pool_fname} | jq
echo "---------------------"
EOF
  echo
}

function set_virtualised_sno_hub_as_installed {

  local hub_id
  hub_id="$(cat ${SHARED_DIR}/hub_pool_info.txt | cut -d' ' -f1)"

  local virtualized_hub_pool_filename
  virtualized_hub_pool_filename="$(cat ${SHARED_DIR}/hub_pool_info.txt | cut -d' ' -f2)"

  local lock_filename
  lock_filename="${virtualized_hub_pool_filename}.lock"

  for ((attempts = 0 ; attempts < ${max_attempts:=5} ; attempts++)); do
    ts=$(date -u +%s%N)
    echo "Locking ${lock_filename} shared file... [${attempts/${max_attempts}}]"
    try_to_lock_host "${AUX_HOST}" "${lock_filename}" "${ts}" "${lock_timeout:="120"}"
    if [[ "$(check_the_host_was_locked "${AUX_HOST}" "${lock_filename}" "${ts}")" == "locked" ]] ; then
      update_selected_vhub_to_use "${virtualized_hub_pool_filename}" "${hub_id}"
      return 0
    fi
    set -x
    sleep 1m
    set +x
  done

  echo
  echo "[WARNING] Dead-Lock condition while trying to install a new virtualised Hub cluster!!!"
  echo "For manual clean up, check out /var/run/lock/ztp-virtualised-hub-pool/*.lock folder in your bastion host"
  echo "and remove the ${lock_filename} file"
  echo "Note that at this point it is ok to continue, but the next attempt to deploy another Hub will fail,"
  echo "until the aforementined clean up had been performed."
  echo
}

function main {

  #### SSH Private key
  export BASTION_VHUB_HOST_SSH_PRI_KEY_FILE="${PWD}/remote-hypervisor-ssh-privkey"
  cat /var/run/telcov10n/ansible-group-all/ansible_ssh_private_key > ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}
  chmod 600 ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}
  setup_aux_host_ssh_access ${BASTION_VHUB_HOST_SSH_PRI_KEY_FILE}

  set_virtualised_sno_hub_as_installed
}

main
