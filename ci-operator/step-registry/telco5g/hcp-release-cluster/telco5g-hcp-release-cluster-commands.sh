#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster release command ************"
# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY

source $SHARED_DIR/main.env
MGMT_CLUSTER="cnfdr15"
CLUSTER_NAME="cnfdr16"
HYPERV_IP=10.1.104.3
HYPERV_HOST=cnfdr3
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

echo "Detaching cluster $CLUSTER_NAME"

# Copy ansible-automation repo locally
mkdir -p $SHARED_DIR/repos
if [[ ! -e "$SHARED_DIR/repos/ansible-automation" ]]; then

    ssh -i $SSH_PKEY $COMMON_SSH_ARGS kni@${HYPERV_IP} \
        "tar --exclude='.git' -czf - -C /home/kni ansible-automation" | tar -xzf - -C $SHARED_DIR/repos/
fi
# Change the host to hypervisor
cd $SHARED_DIR/repos/ansible-automation

sed -i "s/- hosts: localhost/- hosts: ${HYPERV_HOST}/g"  playbooks/remove_bm_cluster.yaml

status=0
ANSIBLE_LOG_PATH=$ARTIFACT_DIR/ansible.log ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    playbooks/remove_bm_cluster.yaml \
    -e kubeconfig=/home/kni/${MGMT_CLUSTER}-kubeconfig \
    -e cluster_name=$CLUSTER_NAME \
    -e ansible_host=${HYPERV_IP} -e ansible_ssh_user=kni -e ansible_ssh_private_key_file="${SSH_PKEY}" \
    -e virtual_cluster_deletion=true || status=$?

# Do any things before exiting if failed
exit ${status}
