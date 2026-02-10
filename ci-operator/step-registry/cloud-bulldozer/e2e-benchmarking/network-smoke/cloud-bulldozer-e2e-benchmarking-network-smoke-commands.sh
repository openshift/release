#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Source shared retry library if available
if [[ -f "${SHARED_DIR}/retry-lib.sh" ]]; then
    source "${SHARED_DIR}/retry-lib.sh"
else
    echo "retry-lib.sh not found in ${SHARED_DIR}"
fi

# Guarantee fallback
if ! declare -F retry_git_clone >/dev/null; then
    echo "retry_git_clone not defined; falling back to plain git clone (no retries)"
    retry_git_clone() { git clone "$@"; }
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
    pushd workloads/network-perf-v2
    oc delete ns netperf --wait=true --ignore-not-found=true
    ES_SERVER="" LOCAL=true ./run.sh
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi
