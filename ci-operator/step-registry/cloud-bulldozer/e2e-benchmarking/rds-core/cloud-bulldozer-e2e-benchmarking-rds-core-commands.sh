#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
pushd /tmp


if [[ "$JOB_TYPE" == "presubmit" ]] && [[ "$REPO_OWNER" = "cloud-bulldozer" ]] && [[ "$REPO_NAME" = "e2e-benchmarking" ]]; then
    if [ ${BAREMETAL} == "true" ]; then
      SSH_ARGS="-i /secret/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
      bastion="$(cat /secret/address)"
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
    git clone https://github.com/${REPO_OWNER}/${REPO_NAME}
    pushd ${REPO_NAME}
    git config --global user.email "ocp-perfscale@redhat.com"
    git config --global user.name "ocp-perfscale"
    git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
    git switch ${PULL_NUMBER}
    pushd workloads/kube-burner-ocp-wrapper
    export WORKLOAD=rds-core
    export EXTRA_VARS="--perf-profile=cpt-pao"
    ES_SERVER="" ITERATIONS=1 ./run.sh

    if [ ${BAREMETAL} == "true" ]; then
      # kill the ssh tunnel so the job completes
      pkill ssh
    fi
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi
