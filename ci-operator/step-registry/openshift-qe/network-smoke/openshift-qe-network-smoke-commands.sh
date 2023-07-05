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

git clone https://github.com/cloud-bulldozer/e2e-benchmarking --depth=1
pushd e2e-benchmarking/workloads/network-perf-v2

# Clean up
oc delete ns netperf --wait=true --ignore-not-found=true

# Smoke Test
./run.sh
