#!/bin/bash
set -eu

SSH_ARGS="-i /secret/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat "/secret/address")

ssh ${SSH_ARGS} root@${bastion} "
  KUBECONFIG=/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig oc adm wait-for-stable-cluster --minimum-stable-period=${MINIMUM_STABLE_PERIOD} --timeout=${TIMEOUT}"
