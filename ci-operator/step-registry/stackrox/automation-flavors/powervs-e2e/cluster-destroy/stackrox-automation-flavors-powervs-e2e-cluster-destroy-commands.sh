#!/bin/bash

set -o errexit
set -o pipefail

SECRET_DIR="/tmp/vault/powervs-rhr-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/PRIVATE_KEY_FILE"

KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

CLUSTER_NAME=$(KUBECONFIG="$KUBECONFIG_FILE" oc config view --minify -o jsonpath='{.clusters[].name}')

SSH_KEY_PATH="/tmp/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"
SSH_CMD="ocp.sh release --name ${CLUSTER_NAME}"

# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

# release a ocp cluster
ssh $SSH_ARGS root@cluster.pool.synergyonpower.com "$SSH_CMD" > $KUBECONFIG_FILE

