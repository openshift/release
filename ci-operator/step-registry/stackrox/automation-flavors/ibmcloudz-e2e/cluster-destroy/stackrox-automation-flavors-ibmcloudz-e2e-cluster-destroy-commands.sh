#!/bin/bash

set -o errexit
set -o pipefail

SECRET_DIR="/tmp/vault/ibmcloudz-rhr-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/PRIVATE_KEY_FILE"
SSH_KEY_PATH="/tmp/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"

# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

# delete k8s cluster. k8smanager script runs on an intermediate node [IP 163.66.94.115] on IBM cloud
# KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"
# SSH_CMD="/home/ubuntu/stackrox-ci/k8smanager delete"
# ssh $SSH_ARGS root@163.66.94.115 "$SSH_CMD" > $KUBECONFIG_FILE

# delete OCP cluster. ocpmanager script runs on an intermediate node [IP 163.74.90.40] on IBM cloud
SSH_CMD="/root/ocpmanager delete"
ssh $SSH_ARGS root@163.74.90.40 "$SSH_CMD"
