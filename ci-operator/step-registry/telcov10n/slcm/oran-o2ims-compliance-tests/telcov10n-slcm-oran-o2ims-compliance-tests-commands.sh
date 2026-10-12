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
ansible-playbook -i robot_inventory.yml playbooks/run_oran_o2ims_compliance_tests.yml -v | tee  ${ARTIFACT_DIR}/ansible.log

# Rename non-upstream junit reports so that they don't show up in spyglass
shopt -s globstar nullglob
for x in ${ARTIFACT_DIR}/**/*junit* ; do
  if [[ ! $x =~ "upstream" ]]; then
    mv $x "$(dirname $x)/$(basename $x | sed 's/junit/results/')";
  else
    export UPSTREAM_JUNIT=$x
  fi
done

pip install --user junitparser

# Need to do this because of a bug in junitparser's verify subcommand which fails if there is only one test suite
# This can be removed when https://github.com/weiwei/junitparser/pull/142 is merged
cat << EOF_SCRIPT > fail_if_any_test_failed.py
import sys
from junitparser import JUnitXml, TestSuite

# this is a copy of the varify sub command but it handles a single testsuite properly
def verify(paths):
  for path in paths:
    xml = JUnitXml.fromfile(path)
    # If there is only one testsuite then make it a
    # list of one so it gets handled properly
    if isinstance(xml, TestSuite):
        xml = [xml]
    for suite in xml:
        for case in suite:
          if not case.is_passed and not case.is_skipped:
            return 1
  return 0

sys.exit(verify(['${UPSTREAM_JUNIT}']))
EOF_SCRIPT

python3 ./fail_if_any_test_failed.py
