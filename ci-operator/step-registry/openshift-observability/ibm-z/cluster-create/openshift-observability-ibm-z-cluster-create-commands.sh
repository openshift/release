#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd


SECRET_DIR="/tmp/vault/ibmz-ci-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/IPI_SSH_KEY"


# Define required values these we can export in the env
#CLUSTER_VERSION=4.18.1
#CLUSTER_NAME=ocp-demo-ci-script
#PULL_SECRET_FILE='/root/ocp-pull-secrte.json'

# install kubectl
#curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
#chmod +x kubectl

# Kubeconfig file
KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

IP_JUMPHOST=128.168.131.205
CLUSTER_VARS_PATH="/root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning/cluster-vars"
SSH_KEY_PATH="/tmp/id_rsa"
SSH_ARGS=" -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"

# Define SSH command just like Power script
SSH_CMD=$(cat <<EOF
set -e

# Append values directly to cluster-vars
{
  echo "CLUSTER_VERSION='${CLUSTER_VERSION}'"
  echo "CLUSTER_NAME='${CLUSTER_NAME}'"
  echo "PULL_SECRET_FILE='${PULL_SECRET_FILE}'"
} >> "$CLUSTER_VARS_PATH"

cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./create-cluster.sh
EOF
)

# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

# Run the SSH command
ssh $SSH_ARGS  root@$IP_JUMPHOST "$SSH_CMD" > "$KUBECONFIG_FILE"

KUBECONFIG="$KUBECONFIG_FILE" ./kubectl get nodes