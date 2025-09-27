#!/bin/bash
set -eu

if [ ${BAREMETAL} == "true" ]; then
  SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
  jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
  bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

  # Step 1: Start SOCKS proxy on jumphost connecting to bastion (runs in background on jumphost)
  ssh ${SSH_ARGS} root@${jumphost} "ssh root@${bastion} -fNT -D 0.0.0.0:12345" &

  # Step 2: Forward the SOCKS proxy from jumphost back to CI host
  ssh ${SSH_ARGS} root@${jumphost} -fNT -L 12345:localhost:12345

  # Give SSH tunnels a moment to establish
  sleep 3

  # Configure proxy settings for oc commands
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345

  # Configure oc to use the proxy
  oc --kubeconfig=${SHARED_DIR}/kubeconfig config set-cluster "$(oc config current-context)" --proxy-url=socks5://localhost:12345
fi

# For disconnected environments, source proxy config if available
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Run cluster health checks locally (proxied for baremetal)
oc version
oc get node
oc adm wait-for-stable-cluster --minimum-stable-period=${MINIMUM_STABLE_PERIOD} --timeout=${TIMEOUT}

# Cleanup SSH tunnels for baremetal (both port forward and SOCKS proxy)
if [ ${BAREMETAL} == "true" ]; then
  pkill ssh
fi