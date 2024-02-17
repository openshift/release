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
    git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER}
    git switch ${PULL_NUMBER}
    pushd workloads/kube-burner-ocp-wrapper
    export WORKLOAD=node-density-heavy
    ES_SERVER="" EXTRA_FLAGS="--pods-per-node=50" ./run.sh
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi