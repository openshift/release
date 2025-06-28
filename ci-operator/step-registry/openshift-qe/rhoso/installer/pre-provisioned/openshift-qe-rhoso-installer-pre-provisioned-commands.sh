#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

cat <<EOF >>/tmp/all.yml
---
lab: $LAB
cloud: $LAB_CLOUD
compute_count: $COMPUTE_COUNT
dt_path: /tmp
ssh_username: $SSH_USERNAME
ssh_password: $SSH_PASSWORD
ssh_key_file: $SSH_KEY
nova_migration_key: $NOVA_MIGRATION_KEY
ctlplane_start_ip: $CTLPLANE_START_IP
environment:
  KUBECONFIG: $KUBECONFIG
EOF

envsubst < /tmp/all.yml > /tmp/all-updated.yml

cat /tmp/all-updated.yml

scp -o ProxyCommand="ssh -W %h:%p root@${bastion}" /tmp/all-updated.yml root@d37-h08-000-r660.rdu2.scalelab.redhat.com:/tmp/all.yml

ssh -J ${SSH_ARGS} root@${bastion} root@d37-h08-000-r660.rdu2.scalelab.redhat.com "
      echo hostname
      git clone https://github.com/masco/RHOSO.git
      cd RHOSO/ansible
      cp -f /tmp/all.yml group_vars/all.yml
      ansible-playbook -vvv main.yml
"
