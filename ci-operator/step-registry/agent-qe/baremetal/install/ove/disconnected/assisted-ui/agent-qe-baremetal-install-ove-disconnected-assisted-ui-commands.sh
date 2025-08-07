#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && { echo "Proxy conf file is not found. Failing."; exit 1; }

source "${SHARED_DIR}/proxy-conf.sh"
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
RENDEZVOUS_IP=$(<"${SHARED_DIR}/node-zero-ip.txt")
PROXY_URL=$(<"${CLUSTER_PROFILE_DIR}"/proxy)

export CLUSTER_NAME
export BASE_DOMAIN
export PULL_SECRET
export RENDEZVOUS_IP
export PROXY_URL

python3.11 assisted-ui/run_agent_tui.py

cp "/tmp/assisted_ui.log" "${SHARED_DIR}/assisted_ui.log"
cp "/tmp/kubeconfig" "${SHARED_DIR}/kubeconfig"
cp "/tmp/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"

export KUBECONFIG=/tmp/kubeconfig
echo "Forcing a 2.5-hour delay to allow other machines to join the bootstrap node."
sleep 2.5h

echo "Check if the cluster installation is successful by verifying that all cluster operators are available and stable."
if ! output=$(oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=60m 2>&1); then
  echo "Cluster was not installed even after waiting for 3.5 hours."
  echo "$output"
  exit 1
else
  echo "$output"
fi