#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Fix user IDs in a container
~/fix_uid.sh

BASTION_ADDRESS="$(cat /var/run/bastion1/bastion-address)"
VPN_URL="$(cat /var/run/bastion1/vpn-url)"
VPN_USERNAME="$(cat /var/run/bastion1/vpn-username)"
# For password with special characters
VPN_PASSWORD=$(cat /var/run/bastion1/vpn-password)

SSH_KEY_PATH=/var/run/telcov10n/ansible_ssh_private_key
SSH_KEY=~/key

JUMP_SERVER_ADDRESS="$(cat /var/run/bastion1/jump-server)"
JUMP_SERVER_USER="$(cat /var/run/telcov10n/ansible_user)"

IFNAME=tun10

function pr_debug_mode_waiting {

  ext_code=$? ; [ $ext_code -eq 0 ] && return

  echo "################################################################################"
  echo "# Entering in the debug mode waiting..."
  echo "################################################################################"

  TZ=UTC
  END_TIME=$(date -d "+10 hour" +%s)
  debug_done=/tmp/debug.done

  while sleep 1m; do

    test -f ${debug_done} && break
    echo
    echo "-------------------------------------------------------------------"
    echo "'${debug_done}' not found. Debugging can continue... "
    now=$(date +%s)
    if [ ${END_TIME} -lt ${now} ] ; then
      echo "Time out reached. Exiting by timeout..."
      break
    else
      echo "Now:     $(date -d @${now})"
      echo "Timeout: $(date -d @${END_TIME})"
    fi
    echo "Note: To exit from debug mode before the timeout is reached,"
    echo "just run the following command from the POD Terminal:"
    echo "$ touch ${debug_done}"

  done

  echo
  echo "Exiting from Pull Request debug mode..."
}

trap pr_debug_mode_waiting EXIT


cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

SSHOPTS=(
  -o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${SSH_KEY}"
)

cat << END_INVENTORY > robot_inventory.yml
---
ungrouped:
  hosts:
    jump_host:
      ansible_host: "${JUMP_SERVER_ADDRESS}"
      ansible_user: "${JUMP_SERVER_USER}"
      ansible_ssh_common_args: "${SSHOPTS[@]}"
      vpn_username: "${VPN_USERNAME}"
      vpn_password: "${VPN_PASSWORD}"
      vpn_url: "${VPN_URL}"
      tun_name: "${IFNAME}"
robots:
  hosts:
    robot:
      ansible_host: ${BASTION_ADDRESS}
      ansible_user: kni
      ansible_ssh_common_args: '-i "${SSH_KEY}" ${SSHOPTS[*]} -o ProxyCommand="ssh -W %h:%p ${SSHOPTS[*]} -i "${SSH_KEY}" -q ${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}"'
      artifacts_dir: "${ARTIFACT_DIR}"
END_INVENTORY

ansible-galaxy collection install ansible.posix
ansible-playbook -i robot_inventory.yml playbooks/run_oran_o2ims_compliance_tests.yml