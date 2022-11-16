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
export JOB_ITERATIONS=10
export WORKLOAD=cluster-density
./run.sh