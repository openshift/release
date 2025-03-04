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
export WORKLOAD=rds-core
ES_SERVER="" ITERATIONS=1 PPROF=false CHURN=false ./run.sh