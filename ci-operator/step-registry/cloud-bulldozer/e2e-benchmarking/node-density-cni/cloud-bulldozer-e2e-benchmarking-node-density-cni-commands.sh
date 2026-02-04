#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Source shared retry library if available
if [[ -f "${SHARED_DIR}/retry-lib.sh" ]]; then
    source "${SHARED_DIR}/retry-lib.sh"
fi

cat /etc/os-release
oc config view
oc projects
pushd /tmp


if [[ "$JOB_TYPE" == "presubmit" ]] && [[ "$REPO_OWNER" = "cloud-bulldozer" ]] && [[ "$REPO_NAME" = "e2e-benchmarking" ]]; then
    retry_git_clone https://github.com/${REPO_OWNER}/${REPO_NAME}
    pushd ${REPO_NAME}
    git config --global user.email "ocp-perfscale@redhat.com"
    git config --global user.name "ocp-perfscale"
    git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
    git switch ${PULL_NUMBER}
    pushd workloads/kube-burner-ocp-wrapper
    export WORKLOAD=node-density-cni
    ES_SERVER="" EXTRA_FLAGS="--pods-per-node=50" ./run.sh
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi
