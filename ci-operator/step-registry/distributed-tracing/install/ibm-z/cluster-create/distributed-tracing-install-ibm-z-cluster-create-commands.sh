#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd

KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"
PRIVATE_KEY_FILE="/root/.ssh/id_rsa"
SSH_KEY_PATH=$PRIVATE_KEY_FILE

SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"

IP_JUMPHOST=128.168.131.205
CLUSTER_VARS_PATH="/root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning/cluster-vars"

SSH_CMD=$(cat <<EOF
export OCP_CLUSTER_VERSION="${OCP_CLUSTER_VERSION}";
export CLUSTER_NAME="${CLUSTER_NAME}";
export PULL_SECRET_FILE="${PULL_SECRET_FILE}";
export IC_API_KEY="${IC_API_KEY}";
echo "OCP_CLUSTER_VERSION=\$OCP_CLUSTER_VERSION" > $CLUSTER_VARS_PATH;
echo "CLUSTER_NAME=\$CLUSTER_NAME" >> $CLUSTER_VARS_PATH;
echo "PULL_SECRET_FILE=\$PULL_SECRET_FILE" >> $CLUSTER_VARS_PATH;
echo "IC_API_KEY=\$IC_API_KEY" >> $CLUSTER_VARS_PATH;
/root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning/create-cluster.sh
EOF
)

ssh $SSH_ARGS root@$IP_JUMPHOST "$SSH_CMD" > "$KUBECONFIG_FILE"

KUBECONFIG="$KUBECONFIG_FILE" ./oc get nodes
