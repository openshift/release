#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

pushd /tmp
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz | tar xz
export HOME=/tmp
export PATH=${PATH}:/tmp
export JOB_TIMEOUT=${JOB_TIMEOUT:-1800}
export REMOTE_CONFIG=https://github.com/cloud-bulldozer/cluster-perf-ci/raw/master/configmap-scale.yml
export REMOTE_METRIC_PROFILE=https://raw.githubusercontent.com/cloud-bulldozer/cluster-perf-ci/master/metric-profiles/etcdapi.yml
export REMOTE_ALERT_PROFILE=https://raw.githubusercontent.com/cloud-bulldozer/cluster-perf-ci/master/alert-profiles/etcdapi-alerts.yml

git clone https://github.com/cloud-bulldozer/e2e-benchmarking.git --depth=1
pushd e2e-benchmarking/workloads/kube-burner

# Trigger workload with remote configuration parameters
./run_clusterdensity_test_fromgit.sh
