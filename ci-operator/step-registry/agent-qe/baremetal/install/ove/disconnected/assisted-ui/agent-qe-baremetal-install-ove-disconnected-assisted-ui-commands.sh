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
PROXY_URL=$(<"${CLUSTER_PROFILE_DIR}/proxy")

export CLUSTER_NAME
export BASE_DOMAIN
export PULL_SECRET
export RENDEZVOUS_IP
export PROXY_URL
export USER_MANAGED_NETWORKING=true

if ! python3.11 assisted-ui/run_agent_tui.py; then
 echo "Assisted UI workflow failed."
 cp /tmp/assisted_ui.log "$ARTIFACT_DIR"
 cp -r /tmp/screenshots/* "$ARTIFACT_DIR"
 exit 1
fi

cp "/tmp/kubeconfig" "${SHARED_DIR}/kubeconfig"
cp "/tmp/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"

export KUBECONFIG=/tmp/kubeconfig
echo "Forcing a 2.5-hour delay to allow other machines to join the bootstrap node."
sleep 2.5h

echo "Checking cluster installation progress by verifying all cluster operators are available and stable."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=60m