#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Building SSHOPTS"

SSHOPTS=(-o 'ConnectTimeout=5'
-o 'StrictHostKeyChecking=no'
-o 'UserKnownHostsFile=/dev/null'
-o 'ServerAliveInterval=90'
-o LogLevel=ERROR
-i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Executing Ansible playbook using inventory file from /var/builds/${NAMESPACE}/"

echo "Run playbook"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" <<EOF
cd /root/bmanzari/agent-bm-deployments/
ansible-playbook -i /var/builds/${NAMESPACE}/agent-install-inventory install.yaml -v
EOF

#/home/agent/install/"${NAMESPACE}"/openshift-install agent wait-for bootstrap-complete --log-level debug
#/home/agent/install/"${NAMESPACE}"/openshift-install agent wait-for install-complete --log-level debug
