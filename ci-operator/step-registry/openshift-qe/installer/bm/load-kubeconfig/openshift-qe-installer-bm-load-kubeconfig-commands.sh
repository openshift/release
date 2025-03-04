#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i /secret/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat "/secret/address")

if [ -z "${KUBECONFIG_PATH}" ]; then
  scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig ${SHARED_DIR}/kubeconfig
else
  scp -q ${SSH_ARGS} root@${bastion}:/$KUBECONFIG_PATH/kubeconfig ${SHARED_DIR}/kubeconfig
fi