#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=yes -oUserKnownHostsFile=/etc/ssh/ssh_known_hosts -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
jumphost=$(cat "${CLUSTER_PROFILE_DIR}/address")
bastion=$(cat "${CLUSTER_PROFILE_DIR}/bastion")

# shellcheck disable=SC2086,SC2087
ssh ${SSH_ARGS} root@"${jumphost}" bash -s <<EOF
set -o errexit
set -o nounset
set -o pipefail

ssh -oStrictHostKeyChecking=yes -oUserKnownHostsFile=/etc/ssh/ssh_known_hosts -o ServerAliveInterval=60 -o ServerAliveCountMax=240 zuul@${bastion} "
  cd /home/zuul/netperf-rhoso18-nfv-e2e-validation
  make e2e-crucible SCENARIO=${SCENARIO} LAB_ENV=~/nfv-e2e/lab-init.env \\
    E2E_EXTRA='--timeout-crucible ${TIMEOUT_CRUCIBLE} --edpm-host ${EDPM_HOST} --frame-sizes ${FRAME_SIZES}'
"
EOF
