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
    git clone https://github.com/${REPO_OWNER}/${REPO_NAME}
    pushd ${REPO_NAME}
    git config --global user.email "ocp-perfscale@redhat.com"
    git config --global user.name "ocp-perfscale"
    git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
    git switch ${PULL_NUMBER}
    pushd workloads/kube-burner-ocp-wrapper
    export WORKLOAD=virt-density
    export EXTRA_FLAGS="--vms-per-node=5 --vmi-ready-threshold=1m"
    ES_SERVER="" PPROF=false ./run.sh
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi
