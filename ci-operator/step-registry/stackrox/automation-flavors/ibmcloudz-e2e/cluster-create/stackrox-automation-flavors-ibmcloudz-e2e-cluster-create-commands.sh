#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl

SECRET_DIR="/tmp/vault/ibmcloudz-rhr-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/PRIVATE_KEY_FILE"
SSH_KEY_PATH="/tmp/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

# https://docs.ci.openshift.org/docs/architecture/step-registry/#sharing-data-between-steps
KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

# The ocpmanager script creates/deletes OCP clusters on IBM Z via IBM Cloud [https://github.ibm.com/Ganesh-Bhure2/stackrox-ci]
# The script runs on an intermediate node [IP 163.74.90.40] on IBM Cloud
SSH_CMD="/root/ocpmanager create"
ssh $SSH_ARGS root@163.74.90.40 "export BUILD_ID=$BUILD_ID && export IBM_CLOUD_OPENSHIFT_CHANNEL=$IBM_CLOUD_OPENSHIFT_CHANNEL && $SSH_CMD" > $KUBECONFIG_FILE
KUBECONFIG="$KUBECONFIG_FILE" ./kubectl get nodes
