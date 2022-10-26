#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

git clone https://github.com/cloud-bulldozer/e2e-benchmarking
pushd e2e-benchmarking/workloads/kube-burner
export WORKLOAD=node-density
export NODE_COUNT=3
export PODS_PER_NODE=245
export POD_READY_THRESHOLD=120000ms
./run.sh
