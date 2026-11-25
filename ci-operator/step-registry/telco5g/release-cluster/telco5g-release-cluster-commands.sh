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

if [[ ! -e ${SHARED_DIR}/cluster_name ]]; then
    echo "Cluster doesn't exist, job failed"
    exit 1
fi

# Get all required variables - cluster name, API IP, port, environment
# shellcheck disable=SC2046,SC2034
IFS=- read -r CLUSTER_NAME CLUSTER_API_IP CLUSTER_API_PORT CLUSTER_ENV <<< $(cat ${SHARED_DIR}/cluster_name)
echo "Releasing cluster $CLUSTER_NAME"
ansible-playbook -i $SHARED_DIR/bastion_inventory $SHARED_DIR/release-cluster.yml -vvvv

# Don't destroy clusters for internal SRIOV jobs
if [[ "$T5CI_JOB_TYPE"  == "sriov" ]]; then
    exit 0
fi
ansible-playbook -i $SHARED_DIR/inventory $SHARED_DIR/destroy-cluster.yml -vv
