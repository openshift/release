#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

cat <<EOF >>/tmp/all.yml
---
lab: $LAB
cloud: $LAB_CLOUD
compute_count: $COMPUTE_COUNT
dt_path: /tmp/RHOSO
ssh_username: $SSH_USERNAME
ssh_password: $SSH_PASSWORD
ssh_key_file: $SSH_KEY
nova_migration_key: $NOVA_MIGRATION_KEY
ctlplane_start_ip: $CTLPLANE_START_IP
ocp_environment:
  KUBECONFIG: /root/mno/kubeconfig
EOF

envsubst < /tmp/all.yml > /tmp/all-updated.yml

cat /tmp/all-updated.yml

scp -q ${SSH_ARGS} /tmp/all-updated.yml root@${bastion}:/tmp/rhoso_all.yml

ssh ${SSH_ARGS} root@${bastion} <<BASTION
  bastion=${bastion}
  ssh root@e31-h02-000-r640.rdu2.scalelab.redhat.com <<TARGET
    echo "Hostname: $(hostname)"
    rm -rf RHOSO
    git clone https://github.com/masco/RHOSO.git
    cd RHOSO/ansible
    scp root@\${bastion}:/tmp/rhoso_all.yml group_vars/all.yml
    ansible-playbook -vvv main.yml 2>&1 | tee log
  TARGET
BASTION
