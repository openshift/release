#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster release command ************"
# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

# Workaround 777 perms on secret ssh password file
KNI_SSH_PASS=$(cat /var/run/kni-pass/knipass)
HYPERV_IP=10.19.16.50

CLUSTER_NAME=$(cat $SHARED_DIR/cluster_name)

cat << EOF > ~/inventory
[all]
${HYPERV_IP} ansible_ssh_user=kni ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90" ansible_password=$KNI_SSH_PASS
EOF
set -x

echo "Releasing cluster $CLUSTER_NAME"

cat << EOF > ~/release-cluster.yml
---
- name: Release cluster $CLUSTER_NAME
  hosts: all
  gather_facts: false
  tasks:

  - name: Release cluster from job
    command: python3 ~/telco5g-lab-deployment/scripts/upstream_cluster.py --release-cluster $CLUSTER_NAME
EOF

ansible-playbook -i ~/inventory ~/release-cluster.yml -vvvv
