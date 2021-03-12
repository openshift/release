#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

pushd /tmp
export HOME=/tmp
export PATH=${PATH}:/tmp
export METADATA_COLLECTION=false

git clone https://github.com/cloud-bulldozer/e2e-benchmarking.git --depth=1
pushd e2e-benchmarking/workloads/network-perf

# Trigger workload
./ run_pod_network_test_fromgit.sh 
