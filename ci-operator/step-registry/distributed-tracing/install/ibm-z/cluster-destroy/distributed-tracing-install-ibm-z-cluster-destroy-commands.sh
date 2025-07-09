#!/bin/bash

set -o errexit
set -o pipefail
set -e

cd /tmp
pwd

#give the path for your sys key.
SSH_KEY_PATH="/tmp/my_sys_key" 
OUTPUT_FILE="/tmp/deletedcluster-logs"
IP_JUMPHOST=128.168.131.205
SSH_ARGS=" -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"


# Define SSH command just like Power script
SSH_CMD=$(cat <<EOF
set -e
cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./delete-cluster.sh
EOF
)


ssh $SSH_ARGS root@$IP_JUMPHOST "$SSH_CMD" >  "$OUTPUT_FILE"
