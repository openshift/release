#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Fix user IDs in a container
~/fix_uid.sh

PIPELINE_DISABLED="$(cat /var/run/bastion1/pipeline_disabled)"
if [[ "${PIPELINE_DISABLED}" == "true" ]]; then
  echo "Pipeline has been disabled. Skipping execution"
  exit 0
fi

BASTION_ADDRESS="$(cat /var/run/bastion1/bastion_address)"
BASTION_USERNAME="$(cat /var/run/bastion1/bastion_username)"
VPN_URL="$(cat /var/run/bastion1/vpn_url)"
VPN_USERNAME="$(cat /var/run/bastion1/vpn_username)"
VPN_PASSWORD=$(cat /var/run/bastion1/vpn_password)

ANSIBLE_GROUP_ALL=/var/run/telcov10n/ansible-group-all/all
SSH_KEY=~/key

JUMP_SERVER_ADDRESS="$(cat /var/run/bastion1/jump_server_address)"
JUMP_SERVER_USERNAME="$(grep -oP "(?<=^ansible_user: ).*" "${ANSIBLE_GROUP_ALL}" | sed -e "s/^'//" -e "s/'\$//")" \
  || { echo "Error: ansible_user not found in ${ANSIBLE_GROUP_ALL}" >&2; exit 1; }
[ -n "${JUMP_SERVER_USERNAME}" ] || { echo "Error: ansible_user is empty in ${ANSIBLE_GROUP_ALL}" >&2; exit 1; }
IFNAME=tun10

# The private key spans several lines in ansible_group_all, take everything between the quotes.
# The file is created 0600 before anything is written to it, so the key is never world-readable.
install -m 600 /dev/null "${SSH_KEY}"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${ANSIBLE_GROUP_ALL}" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${SSH_KEY}"
if [ ! -s "${SSH_KEY}" ]; then
  echo "Error: ansible_ssh_private_key not found in ${ANSIBLE_GROUP_ALL}" >&2
  exit 1
fi

SSHOPTS=(
  -o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o 'IdentitiesOnly=yes'
  -o 'LogLevel=ERROR'
  -i "${SSH_KEY}"
)

cat << END_INVENTORY > inventory.yml
---
ungrouped:
  hosts:
    jump_host:
      ansible_host: "${JUMP_SERVER_ADDRESS}"
      ansible_user: "${JUMP_SERVER_USERNAME}"
      ansible_ssh_private_key_file: "${SSH_KEY}"
      ansible_ssh_common_args: "${SSHOPTS[@]}"
      vpn_username: "${VPN_USERNAME}"
      vpn_password: "${VPN_PASSWORD}"
      vpn_url: "${VPN_URL}"
      tun_name: "${IFNAME}"
    bastion:
      ansible_host: "${BASTION_ADDRESS}"
      ansible_user: "${BASTION_USERNAME}"
      ansible_ssh_private_key_file: "${SSH_KEY}"
      ansible_ssh_common_args: '${SSHOPTS[*]} -o ProxyCommand="ssh -W %h:%p ${SSHOPTS[*]} -q ${JUMP_SERVER_USERNAME}@${JUMP_SERVER_ADDRESS}"'
END_INVENTORY

ansible-galaxy collection install ansible.posix
ansible-playbook -i inventory.yml playbooks/run_performance_benchmark.yml -e "artifact_dir=${ARTIFACT_DIR}" -v | tee ${ARTIFACT_DIR}/ansible.log

python3 ./fail_if_any_test_failed.py
