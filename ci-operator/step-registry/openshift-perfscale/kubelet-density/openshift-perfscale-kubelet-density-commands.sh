#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export QPS=20
export BURST=20
export ES_SERVER=https://search-cloud-perf-lqrf3jjtaqo7727m7ynd2xyt4y.us-west-2.es.amazonaws.com
export ES_PORT=443
export ES_INDEX=ripsaw-kube-burner
export PROM_URL=https://prometheus-k8s.openshift-monitoring.svc.cluster.local:9091
export JOB_TIMEOUT=1800
export WORKLOAD_NODE=""
export CERBERUS_URL=""
export STEP_SIZE=30s
export CLEANUP=false
export CLEANUP_WHEN_FINISH=false
export LOG_LEVEL=info

# Kubelet-density and kubelet-density-heavy specific
export NODE_COUNT=3
export PODS_PER_NODE=50

# Metadata
export METADATA_COLLECTION=true

# kube-burner log streaming
export LOG_STREAMING=true
export CLEANUP_WHEN_FINISH=true

pushd /tmp
curl -sS https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.6.6/openshift-client-linux-4.6.6.tar.gz | tar xz
export PATH=${PATH}:/tmp

git clone https://github.com/cloud-bulldozer/e2e-benchmarking.git --depth=1
pushd e2e-benchmarking/workloads/kube-burner
./run_kubeletdensity_test_fromgit.sh
