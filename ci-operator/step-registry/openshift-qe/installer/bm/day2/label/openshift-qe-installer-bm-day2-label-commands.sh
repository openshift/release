#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if [ ${BAREMETAL} == "true" ]; then
  SSH_ARGS="-i /bm/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    ssh ${SSH_ARGS} root@$bastion "cat ${KUBECONFIG_PATH}" > /tmp/kubeconfig
    export KUBECONFIG=/tmp/kubeconfig
  else
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
  fi
  # Setup socks proxy
  ssh ${SSH_ARGS} root@$bastion -fNT -D 12345
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig="$KUBECONFIG" config set-cluster bm --proxy-url=socks5://localhost:12345
fi

oc config view
oc projects

# Create infra-nodes for ingress-perf testing
if [ ${INFRA} == "true" ]; then
  if [[ $(oc get nodes -l node-role.kubernetes.io/infra= --no-headers | wc -l) != 2 ]]; then
    for node in `oc get nodes -l node-role.kubernetes.io/worker= --no-headers | head -2 | awk '{print $1}'`; do
      oc label node $node node-role.kubernetes.io/infra=""
      oc label node $node node-role.kubernetes.io/worker-;
    done
  fi
fi

if [ ${TELCO} == "true" ]; then
# Label the nodes
  if [ -n "${LABEL}" ]; then
    for node in $(oc get node -oname -l node-role.kubernetes.io/worker | head -n ${LABEL_NUM_NODES} | grep -oP "^node/\K.*"); do
      for label in $(echo "${LABEL}" | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
        if [ -n "$label" ]; then
          echo "Applying label: $label to node: $node"
          oc label node "$node" "$label=" --overwrite
        fi
      done
    done
  fi
fi

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi
