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
    pushd workloads/router-perf-v2

    # Environment setup
    export LARGE_SCALE_THRESHOLD='24'
    export TERMINATIONS='mix'
    export DEPLOYMENT_REPLICAS='1'
    export SERVICE_TYPE='NodePort'
    export NUMBER_OF_ROUTERS='1'
    export HOST_NETWORK='true'
    export NODE_SELECTOR='{node-role.kubernetes.io/worker: }'
    # Benchmark configuration
    export RUNTIME='60'
    export SAMPLES='1'
    export KEEPALIVE_REQUESTS='0 1 5'
    export SMALL_SCALE_ROUTES='5'
    export SMALL_SCALE_CLIENTS='1 5'
    export SMALL_SCALE_CLIENTS_MIX='1 5'
    
    ./ingress-performance.sh 
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi
