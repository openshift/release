#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Setup Bastion
  ## Change default gateway to Bastion host
  ## Host Netserver at $EXTERNAL_SERVER_ADDRESS

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

ssh ${SSH_ARGS} root@${bastion}

ip link add name dummy0 type dummy
ip link set dummy0 up
ip addr add 172.31.0.1/24 dev dummy0
podman run -d --rm --network=host quay.io/cloud-bulldozer/k8s-netperf:latest netserver -D -L 172.31.0.1
