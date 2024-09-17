#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

#su -c '
##!/bin/bash
#set -x
#
#dnf install -y podman
#podman pull quay.io/opendatahub/opendatahub-operator
#' - newRoot

#echo "CHECK: Does buildah work as non-root user with securityContext unprivileged?"
#buildah pull alpine:latest

SECRET_DIR="/tmp/vault/powervs-rhr-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/ODH_POWER_SSH_KEY"
HOME=/tmp
SSH_KEY_PATH="$HOME/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR"


# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

POWERVS_IP=odh-power-node.ecosystemci.cis.ibm.net


echo "Get Shafi Quay Creds from PowerVS"
scp $SSH_ARGS root@POWERVS_IP:/root/shafi_podman_login.sh /tmp/
. /tmp/shafi_podman_login.sh

echo "Check Quay Login"
podman login --get-login quay.io

echo "Build & Push test manifest list"
podman manifest create --amend quay.io/shafi_rhel/opendatahub-operator-test-catalog:multi quay.io/shafi_rhel/opendatahub-operator-test-catalog:amd64 quay.io/shafi_rhel/opendatahub-operator-test-catalog:ppc64le
podman push quay.io/shafi_rhel/opendatahub-operator-test-catalog:multi
