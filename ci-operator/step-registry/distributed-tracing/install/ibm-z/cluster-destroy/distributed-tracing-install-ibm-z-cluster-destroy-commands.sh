#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd

OUTPUT_FILE="/tmp/deletedcluster-logs"
IP_JUMPHOST=128.168.131.205
# Define SSH command just like Power script
SSH_CMD=$(cat <<EOF
set -e


cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./delete-cluster.sh
EOF
)
SSH_ARGS=" -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"

ssh $SSH_ARGS root@$IP_JUMPHOST "$SSH_CMD" > "$OUTPUT_FILE"