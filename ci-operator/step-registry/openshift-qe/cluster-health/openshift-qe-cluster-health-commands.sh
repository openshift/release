#!/bin/bash
set -eu

cleanup_ssh() {
  # Kill the SOCKS proxy running on the jumphost
  ssh ${SSH_ARGS} root@${jumphost} "pkill -f 'ssh root@${bastion} -fNT -D'" 2>/dev/null || true
  # Kill local SSH processes
  pkill ssh
}

if [ ${BAREMETAL} == "true" ]; then
  SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
  jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
  bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

  # Generate a random port between 10000-65535 for SOCKS proxy
  SOCKS_PORT=$((RANDOM % 55536 + 10000))

  # Step 1: Start SOCKS proxy on jumphost connecting to bastion (runs in background on jumphost)
  ssh ${SSH_ARGS} root@${jumphost} "ssh root@${bastion} -fNT -D 0.0.0.0:${SOCKS_PORT}" &

  # Step 2: Forward the SOCKS proxy from jumphost back to CI host
  ssh ${SSH_ARGS} root@${jumphost} -fNT -L ${SOCKS_PORT}:localhost:${SOCKS_PORT}

  # Give SSH tunnels a moment to establish
  sleep 3

  # Configure proxy settings for oc commands
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
  export https_proxy=socks5://localhost:${SOCKS_PORT}
  export http_proxy=socks5://localhost:${SOCKS_PORT}

  # Configure oc to use the proxy
  oc --kubeconfig=${SHARED_DIR}/kubeconfig config set-cluster "$(oc config current-context)" --proxy-url=socks5://localhost:${SOCKS_PORT}

  trap 'cleanup_ssh' EXIT
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
