#!/bin/bash
set -eu
set -o pipefail


curl -sSL https://github.com/kube-burner/kube-burner-ocp/releases/download/${KUBE_BURNER_VERSION}/kube-burner-ocp-${KUBE_BURNER_VERSION}-linux-x86_64.tar.gz | tar xz -C /tmp
rc=0
if  [ ${BAREMETAL} == "true" ]; then
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion "cat ~/bm/kubeconfig" > /tmp/kubeconfig
  # Setup socks proxy
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion -fNT -D 12345
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig=/tmp/kubeconfig config set-cluster bm --proxy-url=socks5://localhost:12345
  cd /tmp
fi

# shellcheck disable=SC2034
for i in {1..10}; do
  if /tmp/kube-burner-ocp cluster-health; then
    break
  fi
  sleep 1m
  rc=1
done

exit $rc
