#!/bin/bash
set -eu

if [ ${BAREMETAL} == "true" ]; then
  SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
  bastion="$(cat ${CLUSTER_PROFILE_DIR}/address)"
  # Setup socks proxy
  ssh ${SSH_ARGS} root@$bastion -fNT -D 12345
  sleep 5
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc config set-cluster "$(oc config current-context)" --proxy-url=socks5://localhost:12345
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