#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Fix user IDs in a container
~/fix_uid.sh

# Read a scalar out of a mounted YAML secret. A YAML parser is used rather than
# grep+sed because stripping quotes with sed also drops apostrophes that belong
# to the value itself (a password like 'pa''ss' would arrive as pass).
read_yaml_key() {
  python3 -c '
import sys, yaml

path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = yaml.safe_load(f)
except yaml.YAMLError:
    # Do not print the parser error: it quotes the offending line of the secret.
    sys.exit("Error: " + path + " is not valid YAML")
if not isinstance(data, dict):
    sys.exit("Error: " + path + " is empty or not a YAML mapping")
if key not in data:
    sys.exit("Error: " + key + " not found in " + path)
sys.stdout.write(str(data[key]))
' "$1" "$2"
}

# Extract the VPN/bastion credentials and SSH private key with tracing off so they never hit the build log.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
BASTION_ADDRESS="$(read_yaml_key /var/run/bastion1/secret bastion-address)" || exit 1
VPN_URL="$(read_yaml_key /var/run/bastion1/secret vpn-url)" || exit 1
VPN_USERNAME="$(read_yaml_key /var/run/bastion1/secret vpn-username)" || exit 1
# For password with special characters
VPN_PASSWORD="$(read_yaml_key /var/run/bastion1/secret vpn-password)" || exit 1

SSH_KEY=~/key

JUMP_SERVER_ADDRESS="$(read_yaml_key /var/run/bastion1/secret jump-server)" || exit 1
JUMP_SERVER_USER="$(read_yaml_key /var/common_variables/ansible_group_all ansible_user)" || exit 1

IFNAME=tun10

# The private key spans several lines in group_vars/all, take everything between the quotes
install -m 600 /dev/null "${SSH_KEY}"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" /var/common_variables/ansible_group_all \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${SSH_KEY}"
if [ ! -s "${SSH_KEY}" ]; then
  echo "Error: ansible_ssh_private_key not found in /var/common_variables/ansible_group_all" >&2
  exit 1
fi
$WAS_TRACING && set -x

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
