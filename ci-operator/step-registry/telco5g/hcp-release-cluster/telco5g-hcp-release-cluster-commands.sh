#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster release command ************"
~/fix_uid.sh

SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"
BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
BASTION_USER="$(cat /var/run/bastion-user/bastionuser)"

source $SHARED_DIR/main.env

if [[ ! -e ${SHARED_DIR}/cluster_name ]]; then
    echo "Cluster doesn't exist, job failed"
    exit 1
fi

# Copy automation repo to local SHARED_DIR
echo "Copy automation repo to local $SHARED_DIR"
mkdir $SHARED_DIR/repos
ssh -i $SSH_PKEY $COMMON_SSH_ARGS ${BASTION_USER}@${BASTION_IP} \
    "tar --exclude='.git' -czf - -C /home/${BASTION_USER} ansible-automation" | tar -xzf - -C $SHARED_DIR/repos/

cd $SHARED_DIR/repos/ansible-automation
cp $SHARED_DIR/inventory inventory/billerica_inventory

ANSIBLE_LOG_PATH=$ARTIFACT_DIR/ansible.log ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    -i $SHARED_DIR/inventory \
    $SHARED_DIR/delete-sno.yml || true

# Get all required variables - cluster name, API IP, port, environment
# shellcheck disable=SC2046,SC2034
IFS=- read -r CLUSTER_NAME CLUSTER_API_IP CLUSTER_API_PORT CLUSTER_ENV <<< $(cat ${SHARED_DIR}/cluster_name)
echo "Releasing cluster $CLUSTER_NAME"
ansible-playbook -i $SHARED_DIR/bastion_inventory $SHARED_DIR/release-cluster.yml -vvvv
