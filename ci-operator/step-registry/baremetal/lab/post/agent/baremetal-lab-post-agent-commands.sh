#!/bin/bash
#
set -o nounset
set -o errexit
set -o pipefail

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=INFO
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@openshift-qe-055.arm.eng.rdu2.redhat.com <<EOF
cd /root/workdir/agent-bm-deployments/
ansible-playbook -i prow_inventory dns_cleanup.yaml
EOF
