#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

oc config view
oc projects
python3 -m virtualenv venv3
source venv3/bin/activate
python --version

pushd /tmp
git clone https://github.com/cloud-bulldozer/e2e-benchmarking
pushd e2e-benchmarking/workloads/kube-burner
./run_clusterdensity_test_fromgit.sh