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

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc config view
oc projects

git clone https://github.com/vishnuchalla/e2e-benchmarking --branch v0.0.1 --depth 1
pushd e2e-benchmarking
pushd workloads/kube-burner-ocp-wrapper
export WORKLOAD=rds-core
ES_SERVER="" ITERATIONS=1 PPROF=false CHURN=false ./run.sh

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi