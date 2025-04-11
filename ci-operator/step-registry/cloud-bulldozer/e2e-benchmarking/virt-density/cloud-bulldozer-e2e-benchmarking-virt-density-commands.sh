#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
pushd /tmp


git clone https://github.com/vishnuchalla/e2e-benchmarking --branch v0.0.1 --depth 1
pushd e2e-benchmarking
pushd workloads/kube-burner-ocp-wrapper
export WORKLOAD=virt-density
ES_SERVER="" PPROF=false ./run.sh
